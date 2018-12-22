# etcd-aws-asg-cluster

Docker image for AWS ASG instances that has some logic to build a cluster by using aws-cli to retrieve a list of ASG members.

*NOTE*: Not even close to production ready. Not using TLS verification between members, for instance. Also, haven't tested failure states.

## Logic

1. Use aws-cli to retrieve ASG membership.
2. Loop A: Do `$RETRIES` times:
    1. Random sleep to spread out instances standing up at the same time.
    2. Loop B: For every member of the ASG
        1. Try to join etcd cluster at ASG member:
            * Connected: Break Loop B and Loop A
            * Not connected: Continue Loop B
    3. If we never connected, and we're first on the ASG member list (sorted alphabetical by instance ID), we make a cluster of 1 node
        * The first in the ASG member list is a requirement to prevent multiple nodes creating clusters
3. Exit

## To consider
List of things I want to implement:

* TLS authentication
* Automatic snapshot to an S3 bucket
* Automatic recovery if building a new cluster

## References
* https://github.com/etcd-io/etcd
* https://pkgs.alpinelinux.org/packages
