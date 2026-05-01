#!/usr/bin/env bash
# Run once after start-replica.sh
set -e
cd ~/icp-lucky-burner

echo "==> Installing NNS (Internet Identity)..."
dfx nns install

echo "==> Deploying our canisters..."
dfx deploy treasury
dfx deploy lottery
dfx deploy frontend

echo "==> Writing .env.local..."
LOTTERY_ID=$(dfx canister id lottery)
TREASURY_ID=$(dfx canister id treasury)
FRONTEND_ID=$(dfx canister id frontend)

cat > src/frontend/.env.local <<EOF
VITE_LOTTERY_CANISTER_ID=$LOTTERY_ID
VITE_TREASURY_CANISTER_ID=$TREASURY_ID
VITE_II_CANISTER_ID=rdmx6-jaaaa-aaaaa-aaadq-cai
VITE_DFX_NETWORK=local
VITE_HOST=http://localhost:8080
EOF

cat src/frontend/.env.local

echo "==> Building frontend..."
cd src/frontend && npm run build && cd ../..

echo "==> Deploying frontend..."
dfx deploy frontend

echo ""
echo "=============================="
echo "SITE: http://$FRONTEND_ID.localhost:8080/"
echo "II:   http://rdmx6-jaaaa-aaaaa-aaadq-cai.localhost:8080/"
echo "=============================="
