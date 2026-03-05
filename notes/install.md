# Installing InfluxDB v2 and Telegraf on Raspberry Pi 5

## Overview
This guide provides step-by-step instructions for installing InfluxDB version 2 and Telegraf as Docker containers on a Raspberry Pi 5. InfluxDB v2 is a time-series database perfect for IoT applications, monitoring, and data visualization with tools like Grafana. Telegraf is a plugin-driven server agent for collecting and reporting metrics from various sources.

## Docker Installation

This guide focuses on Docker container installation for easier deployment, management, and updates. Docker provides better isolation, easier backups, and simplified updates compared to native installation.

### Prerequisites
- Raspberry Pi 5 with Raspberry Pi OS Bookworm (64-bit)
- Docker installed
- Docker Compose (optional but recommended)
- Internet connection

### Install Docker (if not already installed)
```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo apt install docker-compose-plugin
sudo usermod -aG docker $USER
# Log out and back in for group changes to take effect
```

### Create Docker Compose File
Create a `docker-compose.yml` file in your project directory:

```yaml
version: '3.8'

services:
  influxdb:
    image: influxdb:2.8-alpine
    container_name: influxdb
    restart: unless-stopped
    ports:
      - "8086:8086"
    volumes:
      - influxdb_data:/var/lib/influxdb2
    environment:
      - DOCKER_INFLUXDB_INIT_MODE=setup
      - DOCKER_INFLUXDB_INIT_USERNAME=admin
      - DOCKER_INFLUXDB_INIT_PASSWORD=your_secure_password_here
      - DOCKER_INFLUXDB_INIT_ORG=my-org
      - DOCKER_INFLUXDB_INIT_BUCKET=MWPWater
      - DOCKER_INFLUXDB_INIT_ADMIN_TOKEN=my-super-secret-auth-token

  telegraf:
    image: telegraf:1.28-alpine
    container_name: telegraf
    restart: unless-stopped
    depends_on:
      - influxdb
    volumes:
      - ./telegraf.conf:/etc/telegraf/telegraf.conf:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro  # For Docker metrics
      - /proc:/host/proc:ro  # For system metrics
      - /sys:/host/sys:ro    # For system metrics
    environment:
      - INFLUX_TOKEN=my-super-secret-auth-token
    privileged: true  # Required for some system metrics

volumes:
  influxdb_data:
```

### Create Telegraf Configuration
Create a `telegraf.conf` file in the same directory:

```toml
[agent]
  interval = "10s"
  round_interval = true
  metric_batch_size = 1000
  metric_buffer_limit = 10000
  collection_jitter = "0s"
  flush_interval = "10s"
  flush_jitter = "0s"
  precision = ""
  debug = false
  quiet = false
  logfile = ""
  hostname = ""
  omit_hostname = false

[[outputs.influxdb_v2]]
  urls = ["http://influxdb:8086"]
  token = "${INFLUX_TOKEN}"
  organization = "my-org"
  bucket = "MWPWater"

[[inputs.cpu]]
  percpu = true
  totalcpu = true
  collect_cpu_time = false
  report_active = false

[[inputs.disk]]
  ignore_fs = ["tmpfs", "devtmpfs", "devfs", "iso9660", "overlay", "aufs", "squashfs"]

[[inputs.diskio]]

[[inputs.kernel]]

[[inputs.mem]]

[[inputs.processes]]

[[inputs.swap]]

[[inputs.system]]

[[inputs.net]]

# Optional: Docker container metrics
[[inputs.docker]]
  endpoint = "unix:///var/run/docker.sock"
  gather_services = false
  container_names = []
  container_name_include = []
  container_name_exclude = []
  timeout = "5s"
  perdevice = true
  total = false
```

### Start InfluxDB
```bash
docker compose up -d
```

### Start the Stack
```bash
docker compose up -d
```

### Verify Installation
Check that both containers are running:
```bash
docker compose ps
docker compose logs influxdb
docker compose logs telegraf
```

### Docker Management Commands
```bash
# Stop both services
docker compose down

# View logs for both services
docker compose logs -f

# View logs for specific service
docker compose logs -f influxdb
docker compose logs -f telegraf

# Update to latest versions
docker compose pull && docker compose up -d

# Restart services
docker compose restart

# Backup data volume
docker run --rm -v influxdb_influxdb_data:/data -v $(pwd):/backup alpine tar czf /backup/influxdb_backup.tar.gz -C /data .

# Restore from backup
docker run --rm -v influxdb_influxdb_data:/data -v $(pwd):/backup alpine tar xzf /backup/influxdb_backup.tar.gz -C /data .
```

## Equipment Required
- Raspberry Pi 5
- Micro SD Card (32GB or larger recommended) or external storage for Docker volumes
- Power Supply (official Raspberry Pi 5 power supply)
- Ethernet Cable or Wi-Fi connection
- Optional: USB Keyboard, USB Mouse, HDMI Cable for initial setup

## Initial Setup via Web Interface

### 1. Find Your Raspberry Pi's IP Address
```bash
hostname -I
```

### 2. Access InfluxDB Web Interface
Open your web browser and navigate to:
```
http://<YOUR_PI_IP_ADDRESS>:8086
```

(Replace `<YOUR_PI_IP_ADDRESS>` with your actual IP. If accessing from the Pi itself, you can use `http://localhost:8086` or `http://127.0.0.1:8086`)

### 3. Initial User Setup
1. Click "GET STARTED"
2. Fill out the initial user form:
   - Choose a username
   - Set a strong password
   - Confirm the password
3. Click "CONTINUE"

### 4. Save API Token
**IMPORTANT**: InfluxDB will generate an API token. This token provides superuser privileges and will only be shown once.

1. Copy the API token and save it securely
2. Click "QUICK START"

### 5. Choose Your Programming Language
Select your preferred programming language from the available options to see integration examples.

## Raspberry Pi 5 Specific Considerations

- **64-bit Architecture**: Ensure you're using Raspberry Pi OS Bookworm (64-bit) as InfluxDB v2 performs better on 64-bit systems
- **Performance**: The Raspberry Pi 5's improved CPU and RAM make it well-suited for InfluxDB workloads
- **Storage**: Use a high-quality micro SD card or external SSD for better performance with data writes
- **Cooling**: Ensure adequate cooling as InfluxDB can be CPU-intensive during data ingestion

## Next Steps

1. **Complete Initial Setup**: Access the InfluxDB web interface at `http://localhost:8086` to complete the initial setup and get your API token
2. **Update Telegraf Configuration**: If using native installation, update `/etc/telegraf/telegraf.conf` with your actual API token
3. **Create Additional Buckets**: Create `MWPWater_Aggregated` bucket for aggregated data
4. **Configure Data Collection**: Customize Telegraf inputs for your specific monitoring needs
5. **Install Grafana**: For visualization, install Grafana to create dashboards from your data
6. **Set Up Aggregation Tasks**: Configure InfluxDB tasks for data aggregation and downsampling
7. **Backup Strategy**: Set up regular backups of your InfluxDB data

## Troubleshooting

### Docker Issues

#### Container Won't Start
Check the logs:
```bash
docker compose logs influxdb
```

#### Port Already in Use
If port 8086 is already in use:
```bash
# Find what's using the port
sudo lsof -i :8086
# Or change the port mapping in docker-compose.yml
ports:
  - "8087:8086"  # Use port 8087 externally
```

#### Permission Issues
Ensure Docker is properly configured:
```bash
sudo usermod -aG docker $USER
# Log out and back in, or run: newgrp docker
```

#### Data Volume Issues
If you need to reset the data volume:
```bash
docker compose down
docker volume rm influxdb_influxdb_data
docker compose up -d
```

#### Telegraf Configuration Issues
If Telegraf can't connect to InfluxDB:
```bash
# Check Telegraf logs
docker compose logs telegraf

# Test configuration
docker run --rm -v $(pwd)/telegraf.conf:/etc/telegraf/telegraf.conf:ro telegraf:1.28-alpine telegraf --test
```

#### Performance Issues
- Monitor system resources: `htop` or `top`
- Consider adjusting InfluxDB configuration for Raspberry Pi constraints
- Use external storage for large datasets

## Configuration Files
- **InfluxDB**: Default Docker configuration works well for most setups
- **Telegraf**: Configuration is managed via the `telegraf.conf` file mounted into the container

## Uninstalling
```bash
# Stop and remove containers
docker compose down

# Remove volumes (WARNING: This deletes all data!)
docker volume rm influxdb_influxdb_data

# Remove images (optional)
docker rmi influxdb:2.8-alpine telegraf:1.28-alpine
```


## Additional Resources
- [InfluxDB Documentation](https://docs.influxdata.com/influxdb/v2/)
- [Telegraf Documentation](https://docs.influxdata.com/telegraf/)
- [Telegraf Plugin Directory](https://docs.influxdata.com/telegraf/latest/plugins/)
- [Grafana Installation Guide](https://grafana.com/docs/grafana/latest/setup/installation/)
- [Raspberry Pi Documentation](https://www.raspberrypi.com/documentation/)