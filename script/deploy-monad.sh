#!/usr/bin/env bash
set -eo pipefail
RPC=https://testnet-rpc.monad.xyz
export WMON_ADDRESS=0xFb8bf4c1CC7a94c73D209a149eA2AbEa852BC541
# The Pyth Entropy adapter (README, deployed addresses): settles tied Delegate council seats.
export RANDOMNESS_SOURCE=0x422cbB19F504D57cB909AC149e97f48Ba8c1b92D

forge build --via-ir

for M in DAO QuadraticDAO LiquidDAO OptimisticDAO DelegateDAO BoardDAO SortitionDAO ConvictionDAO SowellianDAO DecisionMarketsDAO Wrapper; do
  forge script script/Deploy${M}Factory.s.sol:Deploy${M}Factory \
    --rpc-url $RPC --private-key $PRIVATE_KEY --broadcast --via-ir \
    | tee -a monad-deploy.log
done

# The Launcher may call the token models' factories from this run.
LAUNCH_FACTORIES=$(for F in DAOFactory QuadraticDAOFactory LiquidDAOFactory OptimisticDAOFactory DelegateDAOFactory SortitionDAOFactory ConvictionDAOFactory SowellianDAOFactory DecisionMarketsDAOFactory; do
  grep "  $F deployed at:" monad-deploy.log | tail -1 | awk '{print $NF}'
done | paste -sd, -)
export LAUNCH_FACTORIES
forge script script/DeployLaunchFactory.s.sol:DeployLaunchFactory \
  --rpc-url $RPC --private-key $PRIVATE_KEY --broadcast --via-ir \
  | tee -a monad-deploy.log

grep "Factory deployed at" monad-deploy.log