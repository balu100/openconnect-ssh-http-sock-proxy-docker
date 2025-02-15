# Use the official Alpine base image
FROM alpine

# Copy the script to run OpenConnect and SSH
COPY run.sh /run.sh

# Update package list
RUN apk update

# Install OpenSSH, OpenSSL, OpenConnect, xauth and freefont (forx11forwarding)
RUN apk add --no-cache openssh openssl openconnect dante-server tinyproxy xauth ttf-freefont

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

# Change SSH port from 22 to 8223
RUN sed -i 's/^#\?Port .*/Port 8223/' /etc/ssh/sshd_config || echo 'Port 8223' >> /etc/ssh/sshd_config

# Make the script executable
RUN chmod +x /run.sh

# Set the entrypoint to the script
ENTRYPOINT ["/bin/sh", "/run.sh"]
