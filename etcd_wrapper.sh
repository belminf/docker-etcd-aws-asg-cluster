#!/usr/bin/env sh

# TODO: Be consistent with quotes

set -ex

# Need these env vars
: ${DELAY:=10}
: ${RETRIES:=5}
: ${SPLAY:=10}

not_aws_exit() {
	echo "Could not detect $1, is this AWS? Exiting..."
	exit 1
}

# Get region
export AWS_DEFAULT_REGION="$(timeout -t 3 curl -s 'http://169.254.169.254/latest/dynamic/instance-identity/document' | jq .region -r)"
[ -z "$AWS_DEFAULT_REGION" ] && not_aws_exit 'region'

# Instance and ASG
MY_INSTANCE="$(timeout -t 3 curl -s 'http://169.254.169.254/latest/meta-data/instance-id')"
[ -z "$MY_INSTANCE" ] && not_aws_exit 'instance id'
MY_IP="$(timeout -t 3 curl -s 'http://169.254.169.254/latest/meta-data/local-ipv4')"
[ -z "$MY_IP" ] && not_aws_exit 'private ip'
MY_ASG="$(aws autoscaling describe-auto-scaling-instances --instance-ids "${MY_INSTANCE}" | jq -r '.AutoScalingInstances[0].AutoScalingGroupName')"
[ -z "$MY_ASG" ] && not_aws_exit 'ASG'

get_asg_instances() {

	# Get instances in service
	INSTANCES="$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-name "${MY_ASG}" | jq -r '.AutoScalingGroups[0].Instances | map(select(.LifecycleState == "InService")) | .[].InstanceId' | sort)"

	# First instance should be the first one to start a cluster
	FIRST_INSTANCE="$(echo "$INSTANCES" | head -n1)"
}

etcd_join() {
	local name="$1"
	local ip="$2"
	local endpoint_ip="$3"

	# Run a localhost etcd
	## Needed because if the cluster size is 1, you need etcd running to join and make it 2
	local etcd_join_cluster="$(echo_etcd_join_cluster "$name" "$ip" "$endpoint_ip")"

	# See if add command succeeded
	if [ -n "$etcd_join_cluster" ]; then

		# Now use the
		if etcd_run "$name" "$ip" "$etcd_join_cluster"; then
			echo 'etcd_run succeeded'
			return 0
		else
			echo 'etcd_run failed'
			return 1
		fi

	# Command failed
	else

		# Report the failure
		echo 'Add failed!'
	fi
}

echo_etcd_join_cluster() {
	local name="$1"
	local ip="$2"
	local endpoint_ip="$3"

	# Save member add output
	local join_output="$(etcdctl --endpoint "http://${endpoint_ip}:2379" member add "${name}" "http://${ip}:2380")"

	# Echo the cluster variable
	echo "$join_output" | sed -n '/ETCD_INITIAL_CLUSTER=/ { s/ETCD_INITIAL_CLUSTER=//p }' | tr -d '"'
}

etcd_run() {
	local name="$1"
	local ip="$2"
	local cluster="$3"
	local state="${4:-existing}"

	etcd \
		--name "${name}" \
		--data-dir /etcd-data \
		--initial-advertise-peer-urls "http://${ip}:2380" \
		--listen-peer-urls "http://0.0.0.0:2380" \
		--advertise-client-urls "http://${ip}:2379" \
		--listen-client-urls "http://0.0.0.0:2379" \
		--initial-cluster "${cluster}" \
		--initial-cluster-state "${state}"

	return $?
}

etcd_try_joins() {
	local instances=$1

	# Let's check if anyone wants me to join their cluster!
	echo -e "$instances" | while read this_instance; do

		# Ew, don't try joining myself
		if [ "$this_instance" = "$MY_INSTANCE" ]; then
			continue
		fi

		this_ip="$(aws ec2 describe-instances --instance-ids "$this_instance" | jq -r '.Reservations[].Instances[].PrivateIpAddress')"

		# Try to join
		if etcd_join "$MY_INSTANCE" "$MY_IP" "$this_ip"; then

			# Success, return
			return 0
		else
			echo "Tried joining $this_instance but that didn't work..."
		fi
	done

	# ASSERT: Didn't join anything
	return 1
}

# Retry loop
i=1
while [ "$i" -le "$RETRIES" ]; do

	# Sleep before every interation after first
	if [ "$i" -gt 1 ]; then

		# Sleep DELAY + RANDOM SPLAY
		sleep "$((DELAY + (RANDOM % SPLAY)))s"
	fi

	get_asg_instances

	echo "Attempt $i - Instances: $(echo -e "$INSTANCES" | tr "\n" ' ')"

	# Leave if we joined
	if etcd_try_joins "$INSTANCES"; then
		break
	fi

	# Wait, if I couldn't join anything.. AM I MASTER??! :-D
	if [ "$MY_INSTANCE" = "$FIRST_INSTANCE" ]; then

		# Let's sleep on it and then double check
		echo "Attempt $i - Master candiate: Delaying to double check..."
		sleep "${DELAY}s"
		get_asg_instances

		# They do love me!
		if [ "$MY_INSTANCE" = "$FIRST_INSTANCE" ]; then

			# Start a cluster
			echo "Attempt $i - Master candidate: Still first, creating a new cluster..."
			if etcd_run "$MY_INSTANCE" "$MY_IP" "${MY_INSTANCE}=http://${MY_IP}:2380" new; then
				break
			fi
		fi
	fi

	# Increment try counter
	i=$((i + 1))
done

echo 'Nothing else to do, laters'
