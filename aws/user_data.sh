#!/bin/bash
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

# Update system
apt-get update

# Install Git
apt-get install -y git

# Install Docker
apt-get install -y docker.io
systemctl start docker
systemctl enable docker

# Install AWS CLI
apt-get install -y awscli

# Clone FortressOne server repository
git clone https://github.com/FortressOne/fortressonesv.git /opt/fortressonesv

# Build Docker image
docker build -t fortressone-server /opt/fortressonesv

# --- S3 Map Download ---
# These variables will be replaced by the Ruby bot before sending to AWS
S3_BUCKET="__S3_BUCKET_PLACEHOLDER__" 
MAP_NAME="__MAP_NAME_PLACEHOLDER__" 
HOT_HOSTNAME="__HOSTNAME_PLACEHOLDER__" 

mkdir -p /opt/fortressonesv/fortress/maps/

# Download map from S3
aws s3 cp s3://${S3_BUCKET}/maps/${MAP_NAME}.bsp /opt/fortressonesv/fortress/maps/${MAP_NAME}.bsp

# --- Demo Recording and S3 Upload ---
# Configure game server to record demos (this depends on game server config, assumed to be in fo_quadmode.cfg)
# For example, in server.cfg or fo_quadmode.cfg:
# set demorec 1
# set demopath /opt/fortressone/demos

# Create demos directory on host
mkdir -p /opt/fortressone/demos

# Add a cron job to upload demos to S3
# This assumes the EC2 instance has an IAM role with write access to the S3 bucket
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/bin/aws s3 sync /opt/fortressone/demos/ s3://${S3_BUCKET}/demos/ --delete") | crontab -

# Run FortressOne server in Docker
docker run -d \
  --name fortressone-server \
  -p 27500:27500/udp \
  -p 27500:27500/tcp \
  -v /opt/fortressonesv/fortress/maps/:/opt/fortressone/fortress/maps/ \
  -v /opt/fortressone/demos/:/opt/fortressone/demos/ \
  fortressone-server:latest \
  ./mvdsv +set hostname "${HOT_HOSTNAME}" +exec fo_quadmode.cfg +map "${MAP_NAME}"
