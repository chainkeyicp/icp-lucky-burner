# ICP Lucky Burner

## Deploy locally

```bash
# 1. Start local replica
dfx start --background --clean

# 2. Deploy ledger (local test version)
dfx deploy ledger

# 3. Deploy canisters
dfx deploy treasury
dfx deploy lottery

# 4. Set dev principal (replace with your principal)
dfx canister call treasury setDevPrincipal '("YOUR_PRINCIPAL_HERE")'

# 5. Frontend
cd src/frontend
npm install
npm run build
cd ../..
dfx deploy frontend

# 6. Open in browser
dfx canister id frontend
# → http://localhost:4943?canisterId=<frontend_id>
```

## Dev mode

The app starts in **dev mode** (isDevMode = true).
Use the orange "Simulate End of Day" button to trigger a draw without waiting 24 hours.

To switch to production mode (real 24h timer):
```bash
dfx canister call lottery setDevMode '(false)'
```

## Mainnet deploy

```bash
dfx deploy --network ic
```
