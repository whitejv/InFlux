#!/bin/bash
cd "$(dirname "$0")/.."
influx query \
  --host http://localhost:8086 \
  --org Milano \
  --token "RHl3fYEp8eMLtIUraVPzY4zp_hnnu2kYlR9hYrUaJLcq5mB2PvDsOi9SR0Tu_i-t_183fHb1a95BTJug-vAPVQ==" \
  -f scripts/hourly-aggregate-cli.flux
