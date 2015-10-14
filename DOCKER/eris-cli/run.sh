#! /bin/bash

#default
NUM_NODES=1

#------------------------------------------------------------------
# generate keys and export 

echo "******** SETTING UP KEYS ************"
# run eris-keys, generate a key, get pubkey
# XXX: could clean up if eris-cli had services exec

for ((i=1; i<=$NUM_NODES; i++)) 
do
eris services start keys
ADDR=`eris services exec keys "eris-keys  gen --no-pass"`
# ADDR has an extra character. trim it
ADDRS[$i]=${ADDR%?}
echo "addr_$i ${ADDRS[$i]}"
PUBKEY=`eris services exec keys "eris-keys pub --addr=${ADDRS[$i]}"`
PUBKEYS[$i]=${PUBKEY%?}
echo "pubkey_$i ${PUBKEYS[$i]}"
done

# XXX: we need to get the privkey out as priv_validator.json so we can copy into tendermint container
# This step can be eliminated once tendermint can use eris-keys for signing
# NOTE: I tried and failed to do this through an ENV var, so resorted to saving (and removing) priv_validator.json on the host ...
for ((i=1; i<=$NUM_NODES; i++ ))
do
## XXX: Needs work for multi ...
docker run --rm --volumes-from eris_data_keys_1 -t mct_client mintkey mint ${ADDRS[$i]} > priv_validator.json
done

#------------------------------------------------------------------
# set path and generate genesis.json

echo "******** GENERATE GENESIS.JSON ************"

CHAIN_ID=mintclient_test
TMROOT=/home/eris/.eris/blockchains/$CHAIN_ID
echo "chain_id $CHAIN_ID"
echo "tmroot $TMROOT"

touch genesis.csv
for ((i=1; i<=$NUM_NODES; i++ ))
do	
echo "adding pubkey ${PUBKEYS[$i]} to genesis"
echo "${PUBKEYS[$i]},100000000000" >> genesis.csv
done

# XXX: for multi the first node should be separate (without seed)
#eris chains new --priv=priv_validator.json --csv=genesis.csv --options="moniker=test_nom,seeds=tendermint:46656" $CHAIN_ID
eris chains new --priv=priv_validator.json --csv=genesis.csv --options="moniker=test_nom" $CHAIN_ID

rm priv_validator.json genesis.csv

# XXX: we should offer some special commands like `eris chains plop genesis`
GENESIS=`docker run --rm --volumes-from eris_data_${CHAIN_ID}_1 -t --entrypoint="cat" eris/erisdb:0.10.3 $TMROOT/genesis.json`
echo "genesis $GENESIS"

#------------------------------------------------------------------
# start tendermint

echo "******** RUNNING TENDERMINT ************"
echo "starting seed node..."
#set to the first cont
eris chains start $CHAIN_ID

# run the tendermint container with volumes from tendermint-data
# start i at two, linking each cont to the first, seed is set in config file
#for ((i=2; i<=$NUM_NODES; i++)) 
#do	
### TODO: docker run --name mct_tendermint"_"$i --volumes-from mct_tendermint-data"_"$i --link mct_tendermint_1:tendermint -d mct_tendermint 
#done
# let tendermint start
sleep 3

#------------------------------------------------------------------
# run test

echo "******** INITIALIZING TESTS ************"
for ((i=1; i<=$NUM_NODES; i++ ))
do	
# run the test commands in mint-client container linked to eris-keys and tendermint
docker run --name mct_client_test"_"$i -d --link eris_service_keys_1:keys --link eris_chain_${CHAIN_ID}_1:tendermint -e "CHAIN_ID=$CHAIN_ID" -e "PUBKEY=${PUBKEYS[$i]}" -e "I=$i" -e "NUM_NODES=$NUM_NODES" -t mct_client
done

#stdout logs
for ((i=1; i<=$NUM_NODES; i++ ))
do	
docker logs --follow mct_client_test"_"$i 
done
#------------------------------------------------------------------
# cleanup

if [ "$DONT_CLEANUP" != "true" ]; then
	echo "-----------"
	echo "cleaning up ..."
	for ((i=1; i<=$NUM_NODES; i++ ))
	do	
	eris chains stop -rx $CHAIN_ID
	eris services stop -rx keys
	docker rm mct_client_test_1
	#docker rm -vf mct_keys"_"$i mct_tendermint"_"$i mct_keys-data"_"$i mct_tendermint-data"_"$i mct_client_test"_"$i
	done
fi
