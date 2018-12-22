FROM quay.io/coreos/etcd:v3.3.10

# Need curl, jq and awscli
RUN set -ex \
    && apk update \
    && apk add --no-cache curl jq python \
    && apk add --no-cache --virtual pip-install-deps py-pip \
    && pip install --no-cache-dir  awscli \
    && apk del pip-install-deps

# DELAY - delay before attempting to create new cluster
ENV DELAY 10

# RETRIES - number of retries for a new member to attempt to join a cluster
ENV RETRIES 5

# SPLAY - maximum number of seconds to add to CREATE_DELAY for member retries to be spread out
ENV SPLAY 10

COPY etcd_wrapper.sh /usr/local/bin
CMD ["etcd_wrapper.sh"]
