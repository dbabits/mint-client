#! /bin/bash

# set the default chain id:
CHAIN_ID="mychain"
# location of the blockchain node's rpc server
ERISDB_HOST="localhost:46657"
ERIS_KEYS_HOST="localhost:4767"
SIGN_URL="$ERIS_KEYS_HOST/sign"

# simple solidity contract
read -r -d '' CONTRACT_CODE << EOM 
        contract MyContract {
            function add(int a, int b) constant returns (int sum) {
                sum = a + b;
            }
        }
EOM

usage() {
   cat <<EOF 
    This file is a complete demonstration for the following steps in the eris pipeline
    using nothing but "curl" to talk to HTTP servers and standard unix commands for processing:
    
     0) Install
     1) Start a chain with one validator
     2) Compile a solidity contract
     3) Create and sign transaction to deploy contract
     4) Send the transaction to the blockchain
     5) Wait for a confirmation
     6) Ensure the contract was deployed correctly
     7) Create, sign, broadcast, and wait for transaction that talks to the contract
     8) Query the contract without sending a transaction

    you are expected to:
    - be on a unix platform
    - have golang installed (https://golang.org/doc/install)
    - set \$GOPATH, set GOBIN=\$GOPATH/bin, set PATH=\$GOBIN:\$PATH
    - have jq installed (https://stedolan.github.io/jq/download)

   Usage: $0 -i -c <chain name[$CHAIN_ID]>  -h  

        while getopts "c:isd:t:p:h" opt; do
            case "$opt" in
                c) CHAIN_ID="$OPTARG";; #default is $CHAIN_ID
                i) do_installs;;  #install software
                s) kill_all && start_chain;; #delete $CHAIN_ID directory and re-initialize
                d) compile "$OPTARG" && create_contract_tx && broadcast_tx && wait_for_confirmation && verify_bytecode;;  
                t) call_contract_w_tran "$OPTARG";; #call the contract, creating and committing transaction to the chain
                p) call_contract_no_tran "$OPTARG";;#call the contract, without affecting blockchain state
                h|*) usage;;
            esac
        done

   Sample contract used:
          $CONTRACT_CODE
EOF
   exit 1;
}

strip_quotes(){
    sed 's/\"//g'
    #local s=$1
    #s="${s%\"}"
    #s="${s#\"}"

    #echo $s
}


########################################
## Step 0 - Installs		      ##
########################################
do_installs() {
    #gmp-dev package is needed because eris-keys links to it and needs <gmp.h> 
    #And, jq JSON parser is used throughout (https://stedolan.github.io/jq/download) 
    #These are probably the right commands and package names for a few OSs, but only yum install was tested on AWS AMI
    if [ `which yum 2>/dev/null` ]; then
      sudo yum install -y gmp-devel jq
    elif [ `which apt-get 2>/dev/null` ]; then
      sudo apt-get install libgmp3-dev jq 
    elif [ `which brew 2>/dev/null` ]; then
      brew install gmp jq
    else
      echo "ERROR: unknown OS"
    fi

    # install the keys daemon for signing transactions
    go get github.com/eris-ltd/eris-keys

    # install the mint-client tools
    go get github.com/eris-ltd/mint-client/...

    # install the erisdb (requires branch 0.10.3)
    git clone https://github.com/eris-ltd/eris-db $GOPATH/src/github.com/eris-ltd/eris-db
    cd $GOPATH/src/github.com/eris-ltd/eris-db
    git checkout 0.10.3
    go install ./cmd/erisdb #TODO: this installs into $GOPATH/bin/erisdb - inconsistent naming convention. Everything else has eris-..

    # install the eris-abi tool (required for formatting transactions to contracts)
    go get github.com/eris-ltd/eris-abi/cmd/eris-abi

    exit 0;
}

## Step 0.1 - kill all(reinit)
kill_all() {
    echo "kill_all(): killall erisdb;killall eris-keys; rm -rf ~/.eris/blockchains/$CHAIN_ID"
    killall erisdb
    killall eris-keys
    rm -rf ~/.eris/blockchains/$CHAIN_ID

}

########################################
## Step 1 - Start a chain	      ##
########################################
start_chain() {
    # create genesis file and validator's private key
    # and store them in ~/.eris/blockchains/$CHAIN_ID
    # Expected output:
        #Generating accounts ...
        #genesis.json and priv_validator.json files saved in /home/ec2-user/.eris/blockchains/mychain
    mintgen random 1 $CHAIN_ID

    echo "creating a config file: mintconfig > ~/.eris/blockchains/$CHAIN_ID/config.toml"
    mintconfig > ~/.eris/blockchains/$CHAIN_ID/config.toml

    echo "starting  the chain (erisdb)"
    erisdb ~/.eris/blockchains/$CHAIN_ID  &> ~/.eris/blockchains/$CHAIN_ID/log &
    ps -efww|grep erisdb|grep -v grep

    echo "starting the eris-keys server (for signing transactions)"
    eris-keys server  &> ~/.eris/blockchains/$CHAIN_ID/eris-keys.log &
    ps -efww|grep eris-keys|grep -v grep

    # let everything start up
    sleep 2

    # import the validator's private key into the key server
    # NOTE: this converts the tendermint private key format to the eris private key format
    # This step will be eliminated in the near future as the validator's come to use the eris key format
    ADDRESS=`mintkey eris ~/.eris/blockchains/$CHAIN_ID/priv_validator.json`
    echo "OUR ADDRESS:$ADDRESS"
}

########################################
## Step 2 - Compile Solidity Contract ##
########################################



compile() {
    ADDRESS=$1
    local contract_name=$(echo $CONTRACT_CODE|grep contract|cut -f2 -d ' ')
    echo "compile() ADDRESS=$ADDRESS, contract_name=$contract_name"
    # compile that baby! the solidity code needs to be in base64 for the compile server. And at least on RHEL Linux, base64 wraps long line unless --wrap=0 is passed
    RESULT=$(curl --silent -X POST --data @- --header "Content-Type:application/json" https://compilers.eris.industries:8091/compile <<EOF
    {
        "name":"mycontract",
        "language":"sol",
        "script":"`echo $CONTRACT_CODE|base64 --wrap=0`"
    }
EOF
    )
    # the compile server returns the bytecode (in base64) and the abi (json)
    BYTECODE=`echo $RESULT | jq .bytecode|strip_quotes`
    ABI=`echo $RESULT | jq .abi`


    # convert bytecode to hex
    if [ "$(uname)" == "Darwin" ]; then
       BYTECODE=`echo $BYTECODE | base64 -D | hexdump -ve '1/1 "%.2X"'`
    elif [ "$(uname)" == "Linux" ]; then
       BYTECODE=`echo $BYTECODE | base64 --decode | hexdump -ve '1/1 "%.2X"'`
    else
       echo "ERROR: Uknown OS!!"
    fi

    # unescape quotes in the json
    # TODO: fix the lllc-server so this doesn't happen
    ABI=`eval echo $ABI` 
    ABI=`echo $ABI | jq .`

    ABIFILE=~/.eris/blockchains/$CHAIN_ID/$contract_name.abi
    touch "$ABIFILE"
    echo ABI~$ABI > $ABIFILE
    echo ADDRESS~$ADDRESS >>$ABIFILE

    echo "BYTE CODE:$BYTECODE"
    echo "ABI:$ABI, saved to $ABIFILE"
    ls -l $ABIFILE
    #ABI is needed later in order to call a contract! (must be preserved between compile and execute calls - BAD!)
}

get_pubkey(){
    echo "get_pubkey()"
    #can also do: PUBKEY=`eris-keys pub --addr=$ADDRESS`
    PUBKEY=$(curl -X POST --data @- --silent $ERIS_KEYS_HOST/pub <<EOF |jq .Response | strip_quotes
    {"addr":"$ADDRESS"} 
EOF
    )
}


#################################################################
## Step 3 - Create and Sign Transaction for Deploying Contract ##
#################################################################
create_contract_tx() {
    echo "create_contract_tx()"
    # to create the transaction, we need to know the account's nonce, so we fetch from the blockchain using simple HTTP
    read -r -d '' cmd <<EOF
    curl -X GET http://$ERISDB_HOST/get_account?address='"$ADDRESS"' --silent | jq ."result"[1].account.sequence
EOF

    echo "cmd=$cmd"
    NONCE=`eval "$cmd"`
    #NONCE=`curl -X GET 'http://'"$ERISDB_HOST"'/get_account?address="'"$ADDRESS"'"' --silent | jq ."result"[1].account.sequence`
    echo "NONCE:$NONCE"

    # some variables for the call tx
    CALLTX_TYPE=2 # each tx has a type (they can be found in https://github.com/tendermint/tendermint/blob/develop/types/tx.go. 2=TxTypeCall 
    FEE=0
    GAS=1000
    AMOUNT=1
    NONCE=$(($NONCE + 1)) # the nonce in the transaction must be one greater than the account's current nonce

    # the string that must be signed is a special, canonical, deterministic json structure 
    # that includes the chain_id and the transaction, where all fields are alphabetically ordered and there are no spaces
    SIGN_BYTES='{"chain_id":"'"$CHAIN_ID"'","tx":['"$CALLTX_TYPE"',{"address":"","data":"'"$BYTECODE"'","fee":'"$FEE"',"gas_limit":'"$GAS"',"input":{"address":"'"$ADDRESS"'","amount":'"$AMOUNT"',"sequence":'"$NONCE"'}}]}'

    # we convert the sign bytes to hex to send to the keys server for signing
    SIGN_BYTES_HEX=`echo -n $SIGN_BYTES | hexdump -ve '1/1 "%.2X"'`

    echo "SIGNBYTES:$SIGN_BYTES"
    echo "SIGNBYTES HEX:$SIGN_BYTES_HEX"


    # to sign the SIGN_BYTES, we curl the eris-keys server:
    # (we gave it the private key for this address at the beginning - with mintkey)
    SIGNATURE=$(curl --silent -X POST --data @- $SIGN_URL --header "Content-Type:application/json" <<EOM | jq .Response 
    {
            "msg":"$SIGN_BYTES_HEX",
            "addr":"$ADDRESS"
    }
EOM
    )

    echo "SIGNATURE:$SIGNATURE"
    get_pubkey

    # now we can actually construct the transaction (it's just the sign bytes plus the pubkey and signature!)
    # since it's a CallTx with an empty address, a new contract will be created from the data (the bytecode)
    read -r -d '' CREATE_CONTRACT_TX <<EOM
    [$CALLTX_TYPE, {
            "input":{
                    "address":"$ADDRESS",
                    "amount":$AMOUNT,
                    "sequence":$NONCE,
                    "signature":[1,$SIGNATURE],
                    "pub_key":[1,"$PUBKEY"]
            },
            "address":"",
            "gas_limit":$GAS,
            "fee":$FEE,
            "data":"$BYTECODE"
    }]
EOM

    echo "CREATE CONTRACT TX:$CREATE_CONTRACT_TX"
}


#############################################
## Step 4 - Broadcast tx to the blockchain ##
#############################################
broadcast_tx() {
    echo "broadcast_tx()"
    # package the jsonrpc request for sending the transaction to the blockchain
    JSON_DATA='{"jsonrpc":"2.0","id":"","method":"broadcast_tx","params":['"$CREATE_CONTRACT_TX"']}'
    echo "JSON DATA:$JSON_DATA"

    # broadcast the transaction to the chain!
    CONTRACT_ADDRESS=`curl --silent -X POST -d "${JSON_DATA}" "$ERISDB_HOST" --header "Content-Type:application/json" | jq .result[1].receipt.contract_addr|strip_quotes`


    echo "CONTRACT_ADDRESS:$CONTRACT_ADDRESS"
    echo "CONTRACT_ADDRESS~$CONTRACT_ADDRESS" >> $ABIFILE
}

#############################################
## Step 5 - Wait for a confirmation	   ##
#############################################
wait_for_confirmation() {
    echo "wait_for_confirmation()"
    # now we wait for a block to be confirmed by polling the status endpoint until the block_height increases

    BLOCKHEIGHT_START=`curl -X GET 'http://'"$ERISDB_HOST"'/status' --silent | jq ."result"[1]."latest_block_height"`

    BLOCKHEIGHT=$BLOCKHEIGHT_START

    while [[ "$BLOCKHEIGHT_START" == "$BLOCKHEIGHT" ]]; do
            BLOCKHEIGHT=`curl -X GET 'http://'"$ERISDB_HOST"'/status' --silent | jq ."result"[1]."latest_block_height"`
    done

    echo "BLOCKHEIGHT:$BLOCKHEIGHT"

    # Note we could also set up a websocket connection and subscribe to NewBlock events
    # (eg. subscribeAndWait in github.com/eris-ltd/mint-client/mintx/core/core.go )
}

#############################################
## Step 6 - Verify the contract's bytecode ##
#############################################
verify_bytecode(){
    echo "verify_bytecode()"
    CODE=`curl -X GET 'http://'"$ERISDB_HOST"'/get_account?address="'"$CONTRACT_ADDRESS"'"' --silent | jq ."result"[1].account.code|strip_quotes`

    echo "CODE AT CONTRACT:$CODE"

    # NOTE: CODE won't be exactly equal to BYTECODE 
    # because BYTECODE contains additional code for the actual deployment (the init/constructor sequence of a contract)
    # so we only ensure that BYTECODE contains CODE
    if [[ "$BYTECODE" == *"$CODE"* ]]; then
            echo 'THE CODE WAS DEPLOYED CORRECTLY!' 
    else
            echo 'THE CODE AT THE CONTRACT ADDRESS IS NOT WHAT WE DEPLOYED!'
            echo "Deployed: $BYTECODE"
            echo "Got: $CODE"
    fi
}

parse_abi_file(){
    echo "parse_abi_file()"
    local abifile=$1
    if [ ! -r "$abifile" ]; then echo "ERROR: abifile $abifile does not exist, exiting 1"; exit 1;fi

    ABI=`cat $abifile|grep -w ABI|cut -f2 -d~`
    CONTRACT_ADDRESS=`cat $abifile|grep -w CONTRACT_ADDRESS|cut -f2 -d~`
    ADDRESS=`cat $abifile|grep -w ADDRESS|cut -f2 -d~`

    echo "parse_abi_file() ADDRESS=$ADDRESS,CONTRACT_ADDRESS=$CONTRACT_ADDRESS, abifile=$abifile,ABI=$ABI"
}

format_data() {
    echo "format_data()"
    # we are going to call the "add" function of our contract  and use it to add two numbers
    FUNCTION="add"
    ARG1="25"
    ARG2="37"
    SUM_EXPECTED=$(( $ARG1 + $ARG2 ))

    # we need to format the data for the abi properly
    # this part is tricky because we need to get the function identifier for the function we are trying to call from the contract
    # the function identifier is the first 4 bytes of the sha3 hash of a canonical form of the function signature
    # details are here: https://github.com/ethereum/wiki/wiki/Ethereum-Contract-ABI
    # we use the eris-abi tool to make this simple:

    # TODO: info messages make it to the output the first time around(if ~/.eris/abi does not exist) They need to go to stderr:
    # for that reason we run the command the second time, until this is fixed. Example: echo $DATA
    # Abi directory tree incomplete... Creating it... Directory tree built! a5f3c23b00000000000000000000000000000000000000000000000000000000000000190000000000000000000000000000000000000000000000000000000000000025

    DATA=`eris-abi pack --input file <(echo $ABI) $FUNCTION $ARG1 $ARG2`
    DATA=`eris-abi pack --input file <(echo $ABI) $FUNCTION $ARG1 $ARG2` 
}



verify_result() {
    echo "verify_result()"
    # convert it from hex to int
    SUM_GOT=`echo $((16#$SUM_GOT))`

    if [[ "$SUM_GOT" != "$SUM_EXPECTED" ]]; then
            echo "SMART CONTRACT ADDITION TX FAILED"
            echo "GOT $SUM_GOT"
            echo "EXPECTED $SUM_EXPECTED"
    else
            echo 'SMART CONTRACT ADDITION TX SUCCEEDED!' 
            echo "$ARG1 + $ARG2 = $SUM_GOT"
    fi
}


##################################################################
## Step 7 - Create and Sign Transaction for Talking to Contract ##
##################################################################
call_contract_w_tran() {
    echo "call_contract_w_tran()"

    # some variables for the call tx
    FEE=0
    GAS=1000
    AMOUNT=1

    echo "PUBKEY=$PUBKEY.  DATA FOR CONTRACT CALL:$DATA"

    # since we've already shown how to create a transaction, sign it, and send it to the blockchain using curl,  now we do it simply using the mintx tool.
    # the --sign and --broadcast flags ensure the transaction is signed (by the private key associated with --pubkey)
    # and broadcast to the chain. the --wait flag waits until the transaction is confirmed
    read -r -d '' cmd <<EOF
    mintx call --node-addr=$ERISDB_HOST --chainID=$CHAIN_ID --to=$CONTRACT_ADDRESS --amt=$AMOUNT --fee=$FEE --gas=$GAS --data=$DATA --pubkey=$PUBKEY --sign --broadcast --wait
EOF

    echo "cmd=$cmd"
    RESULT=`eval "$cmd"`

    echo "result=$RESULT"

    # grab the return value
    SUM_GOT=`echo "$RESULT" | grep "Return Value:" | awk '{print $3}' | sed 's/^0*//'`

    verify_result
}

##################################################################
## Step 8 - Talk to Contracts Without Creating Transactions     ##
##################################################################
# It is possible to "query" contracts using the /call endpoint.
# Such queries are only "simulated calls", in that there is no transaction (or signature) required, and hence they have no effect on the blockchain state.
call_contract_no_tran() {
    echo "call_contract_no_tran()"
    SUM_GOT=`curl -X GET 'http://'"$ERISDB_HOST"'/call?fromAddress="'"$ADDRESS"'"&toAddress="'"$CONTRACT_ADDRESS"'"&data="'"$DATA"'"' --silent | jq ."result"[1].return|strip_quotes`

    # strip quotes
    #SUM_GOT="${SUM_GOT%\"}"
    #SUM_GOT="${SUM_GOT#\"}"

    verify_result
}

while getopts "c:isd:t:p:h" opt; do
    case "$opt" in
        c) CHAIN_ID="$OPTARG";; #default is $CHAIN_ID
        i) do_installs;;  #install software
        s) kill_all && start_chain;; #delete $CHAIN_ID directory and re-initialize
        d) compile "$OPTARG" && create_contract_tx && broadcast_tx && wait_for_confirmation && verify_bytecode;;  
        t) parse_abi_file "$OPTARG" && format_data && get_pubkey && call_contract_w_tran ;; #call the contract, creating and committing transaction to the chain
        p) parse_abi_file "$OPTARG" && format_data && call_contract_no_tran;; #call the contract, without affecting blockchain state
        h|*) usage;;
    esac
done

