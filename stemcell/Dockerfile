FROM scratch

ADD  build/image.tgz /

COPY build/bosh-agent /var/vcap/bosh/bin/
COPY assets/agent.json /var/vcap/bosh/
COPY assets/bosh-start-logging-and-auditing /var/vcap/bosh/bin/

RUN rm -rf /warden-cpi-dev && /bin/echo -e "\numount /etc/resolv.conf >/dev/null 2>&1 || true" >> /var/vcap/bosh/bin/bosh-agent-rc
