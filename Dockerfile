# Use the official Alpine base image
FROM alpine

# Copy the script to run OpenConnect and SSH
COPY run.sh /run.sh

# Update package list
RUN apk update

# Install OpenSSH, OpenSSL, and OpenConnect
RUN apk add --no-cache openssh openssl openconnect dante-server tinyproxy xauth ttf-freefont nmap-ncat autossh ansible

# Create .ssh directory for root user
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh

# Create the SSH directory
RUN mkdir /var/run/sshd
RUN mkdir /var/run/sockd
RUN mkdir /var/run/tinyproxy

# Generate SSH host keys
RUN ssh-keygen -A

# Allow root login
RUN sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config

# Enable TCP forwarding
RUN sed -i 's/^#\?AllowTcpForwarding .*/AllowTcpForwarding yes/' /etc/ssh/sshd_config || echo 'AllowTcpForwarding yes' >> /etc/ssh/sshd_config

# Enable agent forwarding
RUN sed -i 's/^#\?AllowAgentForwarding .*/AllowAgentForwarding yes/' /etc/ssh/sshd_config || echo 'AllowAgentForwarding yes' >> /etc/ssh/sshd_config

# Allow gateway ports
RUN sed -i 's/^#\?GatewayPorts .*/GatewayPorts yes/' /etc/ssh/sshd_config || echo 'GatewayPorts yes' >> /etc/ssh/sshd_config

# Enable x11 forwarding
RUN sed -i 's/^#\?X11Forwarding .*/X11Forwarding yes/' /etc/ssh/sshd_config || echo 'X11Forwarding yes' >> /etc/ssh/sshd_config

# Change SSH port from 22 to 8223
RUN sed -i 's/^#\?Port .*/Port 8223/' /etc/ssh/sshd_config || echo 'Port 8223' >> /etc/ssh/sshd_config

# Tell all future login shells to source our agent environment file if it exists
RUN echo -e '\nif [ -f /root/.ssh/agent.env ]; then\n  . /root/.ssh/agent.env\nfi' >> /etc/profile

# Make the script executable
RUN chmod +x /run.sh

# Set the entrypoint to the script
ENTRYPOINT ["/bin/sh", "/run.sh"]
