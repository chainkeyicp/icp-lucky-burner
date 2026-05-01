#!/usr/bin/env bash
fuser -k 8080/tcp 2>/dev/null || true
sleep 2
cd ~/icp-lucky-burner
dfx start --clean
