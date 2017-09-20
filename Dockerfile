FROM centos:7
LABEL application="rsyslog" \
  maintainer='Jean-Pierre van Riel <jp.vanriel@gmail.com>' \
  version='8.29.0-1' \
  release-date='2017-09-16'

ENV container=docker

# Embed custom org CA into image if need be
COPY etc/pki/ca-trust/source/anchors/* /etc/pki/ca-trust/source/anchors/
RUN update-ca-trust

# Setup repos, etc
# Disable fast mirror plugin to better leverage upstream proxy caching (or use specific repos)
# Switch yum config to use a consitant base url (useful if not caching docker build, but relying on an upstream proxy)
ARG DISABLE_YUM_MIRROR=false
RUN if [ "$DISABLE_YUM_MIRROR" != true ]; then exit; fi && \
  sed 's/enabled=1/enabled=0/g' -i /etc/yum/pluginconf.d/fastestmirror.conf && \
  sed 's/^mirrorlist/#mirrorlist/g' -i /etc/yum.repos.d/CentOS-Base.repo && \
  sed 's/^#baseurl/baseurl/g' -i /etc/yum.repos.d/CentOS-Base.repo
# Some rsyslog modules have dependancies in epel
RUN yum --setopt=timeout=120 -y update && \
  yum -y install --setopt=timeout=120 --setopt=tsflags=nodocs epel-release
# Also switch to a base url for epel repo
RUN if [ "$DISABLE_YUM_MIRROR" != true ]; then exit; fi && \
  sed 's/^mirrorlist/#mirrorlist/g' -i /etc/yum.repos.d/epel.repo && \
  sed 's/^#baseurl/baseurl/g' -i /etc/yum.repos.d/epel.repo

# Install Rsyslog. For http://rpms.adiscon.com/v8-stable/rsyslog.repo
# - It has gpgcheck=0
# - Adiscon doens't offer an HTTPS endpoint for the above file :-/
# - The GPG key is at http://rpms.adiscon.com/RPM-GPG-KEY-Adiscon, so also not secure to download and trust directly
# Therefore, prebundle our own local copy of the repo and GPG file
COPY etc/pki/rpm-gpg/RPM-GPG-KEY-Adiscon /etc/pki/rpm-gpg/RPM-GPG-KEY-Adiscon
COPY etc/yum.repos.d/rsyslog.repo /etc/yum.repos.d/rsyslog.repo
RUN yum --setopt=timeout=120 -y update && \
  yum --setopt=timeout=120 --setopt=tsflags=nodocs -y install \
  rsyslog \
  rsyslog-gnutls \
	adisconbuild-librdkafka1 \
  rsyslog-kafka \
  rsyslog-relp \
  lsof \
  && yum clean all
RUN rm -r /etc/rsyslog.d/ \
  && rm /etc/rsyslog.conf

# Install confd
ENV CONFD_VER='0.13.0'
#ADD https://github.com/kelseyhightower/confd/releases/download/v${CONFD_VER}/confd-${CONFD_VER}-linux-amd64 /usr/local/bin/confd
COPY usr/local/bin/confd-0.13.0-linux-amd64 /usr/local/bin/confd
  # Use bundled file to avoid downloading all the time
RUN chmod +x /usr/local/bin/confd && \
  mkdir -p /etc/confd/conf.d && \
  mkdir -p /etc/confd/templates

# Copy rsyslog config templates (for confd)
COPY etc/confd /etc/confd

# Copy rsyslog config files and create folders for template config
COPY etc/rsyslog.conf /etc/rsyslog.conf
COPY etc/rsyslog.d/input/ /etc/rsyslog.d/input/
COPY etc/rsyslog.d/output/ /etc/rsyslog.d/output/
# Directories intended as optional v0lume mounted config
RUN mkdir -p \
  /etc/rsyslog.d/filter \
  /etc/rsyslog.d/output/forward_extra
# Note:
# - rsyslog.d/output/extra is a volume used for unforseen custom outputs
# - rsyslog.d/filter is a volume used for unforseen custom input filters
# - filters that apply to a specific forwarder should rather be done within that forwarders ruleset

# Copy a default self-signed cert and key - this is INSECURE and for testing/build purposes only
# - To help handle cases when the rsyslog tls volume doesn't have expected files present
# - rsyslog.sh entrypoint script will symlink and use these defaults if not provided in a volume
# - For production, avoid insecure default by providing an /etc/pki/rsyslog volume provisioned with your own keys and certficates
COPY etc/pki/tls/certs/default_self_signed.cert.pem /etc/pki/tls/certs
COPY etc/pki/tls/private/default_self_signed.key.pem /etc/pki/tls/private

# Default ENV vars for rsyslog config
# Globals
ENV rsyslog_global_ca_file='/etc/pki/tls/certs/ca-bundle.crt' \
  rsyslog_server_cert_file='/etc/pki/rsyslog/cert.pem' \
  rsyslog_server_key_file='/etc/pki/rsyslog/key.pem'
# Inputs
# Note 'anon' or 'x509/certvalid' or 'x509/name' for ...auth_mode
ENV rsyslog_module_imtcp_stream_driver_auth_mode='anon' \
  rsyslog_tls_permitted_peer='["*"]' \
  rsyslog_module_impstats_interval='300'
# filtering, templates and outputs
# See 60-output_format.conf.tmpl
ENV rsyslog_filtering_enabled=false \
  rsyslog_support_metadata_formats=false \
  rsyslog_omfile_enabled=true \
  rsyslog_omfile_template='RSYSLOG_TraditionalFileFormat' \
  rsyslog_omkafka_enabled=false \
  rsyslog_omkafka_broker='' \
  rsyslog_omkafka_confParam='' \
  rsyslog_omkafka_topic='syslog' \
  rsyslog_omkafka_dynatopic='off' \
  rsyslog_omkafka_topicConfParam='' \
  rsyslog_omkafka_template='TmplRFC5424Format' \
  rsyslog_omfwd_syslog_enabled=false \
  rsyslog_omfwd_syslog_host='' \
  rsyslog_omfwd_syslog_port=514 \
  rsyslog_omfwd_syslog_protocol='tcp' \
  rsyslog_omfwd_syslog_template='TmplRFC5424Format' \
  rsyslog_omfwd_json_enabled=false \
  rsyslog_omfwd_json_host='' \
  rsyslog_omfwd_json_port=5000 \
  rsyslog_omfwd_json_template='TmplJSON' \
  rsyslog_forward_extra_enabled=false

#TODO: check how not to lose/include orginal host if events are relayed
#TODO: check if it's possible to add/tag 5424 with metadata about syslog method used (e.g. strong auth, just SSL sever, weak udp security)
#TODO: 5424 format (rfc5424micro)?

# Note, output config will probably be highly varied, so instead of trying to template it, we allow for that config to be red from a volume and managed by simply picking up from a forward ruleset

#TODO: understand which "stateful" runtime directories rsyslog should have in order to perist accross errors/container runs
# Volumes required
VOLUME /var/log/remote \
  /var/lib/rsyslog \
  /etc/pki/rsyslog
# Extra optional volumes that could be supplied at runtime
# - /etc/rsyslog.d/output/forward_extra
# - /etc/rsyslog.d/filter

# Ports to expose
# Note: UDP=514, TCP=514, TCP Secure=6514, RELP=2514, RELP Secure=7514, RELP Secure with strong client auth=8514
EXPOSE 514/udp 514/tcp 6514/tcp 2514/tcp 7514/tcp 8514/tcp

#TODO: also, decide if we will accept the signal to reload config without restarting the container

COPY usr/local/bin/entrypoint.sh usr/local/bin/rsyslog_healthcheck.sh usr/local/bin/rsyslog_healthcheck.sh usr/local/bin/rsyslog_config_expand.py /usr/local/bin/

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

HEALTHCHECK CMD /usr/local/bin/rsyslog_healthcheck.sh
