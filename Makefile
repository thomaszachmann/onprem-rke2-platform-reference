.PHONY: lint bootstrap servers agents post longhorn cert-manager kyverno kyverno-policies network-policies monitoring logging install-rke2 install-longhorn all clean

lint:
	ansible-lint playbooks/*.yml roles/

bootstrap:
	ansible-playbook playbooks/00-bootstrap.yml

servers:
	ansible-playbook playbooks/10-rke2-servers.yml

agents:
	ansible-playbook playbooks/20-rke2-agents.yml

post:
	ansible-playbook playbooks/30-post.yml

longhorn:
	ansible-playbook playbooks/40-longhorn.yml

cert-manager:
	ansible-playbook playbooks/45-cert-manager.yml

kyverno:
	ansible-playbook playbooks/50-kyverno.yml

kyverno-policies:
	ansible-playbook playbooks/51-kyverno-policies.yml

network-policies:
	ansible-playbook playbooks/52-network-policies.yml

monitoring:
	ansible-playbook playbooks/55-monitoring.yml

logging:
	ansible-playbook playbooks/56-logging.yml

install-rke2: bootstrap servers agents post

install-longhorn: longhorn

all: bootstrap servers agents post longhorn cert-manager kyverno kyverno-policies network-policies monitoring logging

clean:
	rm -rf artifacts/
