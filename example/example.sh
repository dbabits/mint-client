#! /bin/bash

#set -E
#trap '[ "$?" -ne 77 ] || exit 77' ERR

# set the default chain id:
CHAIN_ID="mychain"
# location of the blockchain node's rpc server
ERISDB_HOST="localhost:46657"
ERIS_KEYS_HOST="localhost:4767"
SIGN_URL="$ERIS_KEYS_HOST/sign"

NORM=`tput sgr0`
BOLD=`tput bold`
REV=`tput smso`
RED=`tput setaf 1`
GREEN=`tput setaf 2`
# simple solidity contract - this is just an example. real one is read below from stdin
read -r -d '' CONTRACT_CODE << EOM 
        contract MyContract {
            function add(int a, int b) constant returns (int sum) {
                sum = a + b;
            }
        }
EOM


read_contract_code(){
    if tty -s; then echo 1>&2  "${BOLD}type${NORM} your contract here and terminate with ${REV}Ctrl-D${NORM}:";fi #if we are at keyboard (not a pipe), print this prompt
    local contract_code=$(</dev/stdin) 
    echo "$contract_code"
}

show_genesis(){
    curl -X GET http://$ERISDB_HOST/genesis --silent|jq

}

usage() {
   cat <<EOF 
    This file is a complete demonstration for the following steps in the eris pipeline
    using nothing but "curl" to talk to HTTP servers and standard unix commands for processing:
    

    you are expected to:
    - be on a unix platform
    - have golang installed (https://golang.org/doc/install)
    - set \$GOPATH, set GOBIN=\$GOPATH/bin, set PATH=\$GOBIN:\$PATH
    - have jq installed (https://stedolan.github.io/jq/download)


   Usage: 
   1) install the software: 
      $0 -i
   2) Start a chain with one validator.Kill any running eris-db and eris-keys daemons, delete $CHAIN_ID directory and re-initialize everything.This call will return an account # which you will need later: 
      $0 -s CHAIN_ID
   3) look at genesis for the chain created in step 2 and get the account if you forgot it
      $0 -g
   4) deploy your contract. -d ADDRESS from step 2 or 3.  
      This call will return the filename where ABI for the contract is saved, you will need this file in order to call the contract
      Contract code is expected on stdin, here's an example call: 

cat <<EnD | $0 -d F1665A1B550E27B4545875879B593668CF25F9BE
          $CONTRACT_CODE
EnD 

   5) Look up all abi files (they are named CONTRACT_NAME.abi)
      $0 -j
   6) Call this contract without creating a transaction-pass abifile from step 4 or 5,function name to call, and any arguments,positionally,example:
      $0 -p /home/ec2-user/.eris/blockchains/mychain/MyContract.abi add 17 20
   7) Same thing as in 6), only this time create transaction on the chain and wait for confirmation:
      $0 -t /home/ec2-user/.eris/blockchains/mychain/MyContract.abi add 17 20
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

hex2int() {
    # convert it from hex to int
    RESULT=`echo $((16#$RESULT))`
}

echoerr(){
   cat <<< "$@" 1>&2
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
    CHAIN_ID=$1
    echo "kill_all(): killall erisdb;killall eris-keys; rm -rf ~/.eris/blockchains/$CHAIN_ID"
    killall erisdb
    killall eris-keys
    rm -rf ~/.eris/blockchains/$CHAIN_ID

}

########################################
## Step 1 - Start a chain	      ##
########################################
start_chain() {
    CHAIN_ID=$1
    # create genesis file and validator's private key
    # and store them in ~/.eris/blockchains/$CHAIN_ID
    # Expected output:
        #Generating accounts ...
        #genesis.json and priv_validator.json files saved in /home/ec2-user/.eris/blockchains/mychain
    mintgen random 1 $CHAIN_ID

    echo "creating a config file: mintconfig > ~/.eris/blockchains/$CHAIN_ID/config.toml"
    mintconfig > ~/.eris/blockchains/$CHAIN_ID/config.toml

    echo "starting  the chain (erisdb)"
    local logfile=~/.eris/blockchains/$CHAIN_ID/erisdb.log
    erisdb ~/.eris/blockchains/$CHAIN_ID  > $logfile  2>&1 &
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
    echo "$CHAIN_ID ADDRESS:$ADDRESS"
    echo "logfile:"
    ls -l $logfile
}

########################################
## Step 2 - Compile Solidity Contract ##
########################################



compile() {
    local ADDRESS=$1
    local CONTRACT_CODE=$2
    local abifile=$3
    echoerr "compile() ADDRESS=$ADDRESS, abifile=$abifile"
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
       echoerr "ERROR: Uknown OS!!"
    fi

    # unescape quotes in the json
    # TODO: fix the lllc-server so this doesn't happen
    ABI=`eval echo $ABI` 
    ABI=`echo $ABI | jq .`

    echo ABI~$ABI > $abifile
    echo ADDRESS~$ADDRESS >>$abifile

    echoerr "BYTE CODE:$BYTECODE"
    echoerr "ABI:$ABI, saved to $abifile"
    ls -l $abifile 1>&2
    echo "$BYTECODE"
    #ABI is needed later in order to call a contract! (must be preserved between compile and execute calls - BAD!)
}

function get_pubkey() {
    local address=$1
    echoerr "get_pubkey(ADDRESS=$address)"
    #can also do: pubkey=`eris-keys pub --addr=$address`
    local pubkey=$(curl -X POST --data @- --silent $ERIS_KEYS_HOST/pub <<EOF |jq .Response | strip_quotes
    {"addr":"$address"} 
EOF
    )
    echoerr "get_pubkey(ADDRESS=$ADDRESS) returning $pubkey"
    PUBKEY=$pubkey
    echo "$pubkey"
}


#################################################################
## Step 3 - Create and Sign Transaction for Deploying Contract ##
#################################################################
create_contract_tx() {
    local address=$1
    local pubkey=$2
    local bytecode=$3
    echoerr "create_contract_tx(address=$address,pubkey=$pubkey)"
    # to create the transaction, we need to know the account's nonce, so we fetch from the blockchain using simple HTTP
    read -r -d '' cmd <<EOF
    curl -X GET http://$ERISDB_HOST/get_account?address='"$address"' --silent | jq ."result"[1].account.sequence
EOF

    echoerr "cmd=$cmd"
    NONCE=`eval "$cmd"`
    echoerr "NONCE:$NONCE"

    # some variables for the call tx
    CALLTX_TYPE=2 # each tx has a type (they can be found in https://github.com/tendermint/tendermint/blob/develop/types/tx.go. 2=TxTypeCall 
    FEE=0
    GAS=1000
    AMOUNT=1
    NONCE=$(($NONCE + 1)) # the nonce in the transaction must be one greater than the account's current nonce

    # the string that must be signed is a special, canonical, deterministic json structure 
    # that includes the chain_id and the transaction, where all fields are alphabetically ordered and there are no spaces
    SIGN_BYTES='{"chain_id":"'"$CHAIN_ID"'","tx":['"$CALLTX_TYPE"',{"address":"","data":"'"$bytecode"'","fee":'"$FEE"',"gas_limit":'"$GAS"',"input":{"address":"'"$address"'","amount":'"$AMOUNT"',"sequence":'"$NONCE"'}}]}'

    # we convert the sign bytes to hex to send to the keys server for signing
    SIGN_BYTES_HEX=`echo -n $SIGN_BYTES | hexdump -ve '1/1 "%.2X"'`

    echoerr "SIGNBYTES:$SIGN_BYTES"
    echoerr "SIGNBYTES HEX:$SIGN_BYTES_HEX"


    # to sign the SIGN_BYTES, we curl the eris-keys server:
    # (we gave it the private key for this address at the beginning - with mintkey)
    SIGNATURE=$(curl --silent -X POST --data @- $SIGN_URL --header "Content-Type:application/json" <<EOM | jq .Response 
    {
            "msg":"$SIGN_BYTES_HEX",
            "addr":"$address"
    }
EOM
    )

    echoerr "SIGNATURE:$SIGNATURE"

    # now we can actually construct the transaction (it's just the sign bytes plus the pubkey and signature!)
    # since it's a CallTx with an empty address, a new contract will be created from the data (the bytecode)
    read -r -d '' CREATE_CONTRACT_TX <<EOM
    [$CALLTX_TYPE, {
            "input":{
                    "address":"$address",
                    "amount":$AMOUNT,
                    "sequence":$NONCE,
                    "signature":[1,$SIGNATURE],
                    "pub_key":[1,"$pubkey"]
            },
            "address":"",
            "gas_limit":$GAS,
            "fee":$FEE,
            "data":"$bytecode"
    }]
EOM

    echoerr "CREATE CONTRACT TX:$CREATE_CONTRACT_TX"
    echo "$CREATE_CONTRACT_TX"
}


#############################################
## Step 4 - Broadcast tx to the blockchain ##
#############################################
broadcast_tx() {
    local create_contract_tx=$1
    local abifile=$2
    echoerr "broadcast_tx($create_contract_tx)"
    # package the jsonrpc request for sending the transaction to the blockchain
    local json_data='{"jsonrpc":"2.0","id":"","method":"broadcast_tx","params":['"$create_contract_tx"']}'
    echoerr "json_data:$json_data"

    # broadcast the transaction to the chain!
    CONTRACT_ADDRESS=`curl --silent -X POST -d "${json_data}" "$ERISDB_HOST" --header "Content-Type:application/json" | jq .result[1].receipt.contract_addr|strip_quotes`


    echoerr "CONTRACT_ADDRESS:$CONTRACT_ADDRESS"
    echo "CONTRACT_ADDRESS~$CONTRACT_ADDRESS" >> $abifile
    echo "$CONTRACT_ADDRESS"
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
    local CONTRACT_ADDRESS=$1
    BYTECODE=$2
    echo "verify_bytecode(CONTRACT_ADDRESS=$CONTRACT_ADDRESS,BYTECODE)"
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

process_args() {
    args="$@"
    echo "args=$args"
    echo "[$1] [$2] [$3] [$4] [$5]"

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

#TODO: make proper local vars and functions to return values
    call_contract(){
        local abifile=$2
        parse_abi_file "$abifile"
        format_data "$@" 
        call_contract_no_tran 
        verify_result #call the contract, creating and committing transaction to the chain.#quotes are a must to be able to pass args with spaces

    }

    call_contract2(){
        local abifile=$2
        parse_abi_file "$abifile"
        format_data "$@" 
        local pubkey=$(get_pubkey $ADDRESS)   
        call_contract_w_tran $pubkey
        verify_result #call the contract, creating and committing transaction to the chain.#quotes are a must to be able to pass args with spaces

    }

deploy_contract() {
   local address=$1
   echo "deploy_contract(address=$address)"
   local contract_code=$(read_contract_code);
   if [ -z "${contract_code// }" ]; then echo 1>&2 "${RED}ERROR:${NORM}contract code is empty, exiting 1"; exit 1; fi 

   local contract_name=$(echo $contract_code|grep contract|cut -f2 -d ' ')
   local abifile=~/.eris/blockchains/$CHAIN_ID/$contract_name.abi
   touch "$abifile"

   local bytecode=$(compile $address "$contract_code" $abifile) 
   local pubkey=$(get_pubkey $address)   
   local create_contract_tx=$(create_contract_tx $address $pubkey $bytecode)  
   local contract_address=$(broadcast_tx "$create_contract_tx" $abifile) #returns CONTRACT_ADDRESS. quotes are a must here because of spaces in the var
   wait_for_confirmation
   verify_bytecode $contract_address $bytecode #queries contract_address, gets the code and compares it with BYTECODE created by compile()

   echo "abifile:"
   ls -l $abifile
}


show_abi_files() {
   echo "show_abi_files"
   find ~/.eris/blockchains/ -type f -name '*.abi' -ls

}

format_data() {
    echoerr "format_data()"

    ARGS="$@"
    echoerr "ARGS=$ARGS"
    echoerr "[$1] [$2] [$3] [$4] [$5]"

    switch=$1
    abifile=$2
    # we are going to call the "add" function of our contract  and use it to add two numbers
    FUNCTION="$3"
    ARGS=${@:4} #this syntax means all members of the array starting from 3. $1 is the switch, $2 is the abifile, $4 is function name, the rest are arguments
    #RESULT_EXPECTED=$(( $ARG1 + $ARG2 ))

    # we need to format the data for the abi properly
    # this part is tricky because we need to get the function identifier for the function we are trying to call from the contract
    # the function identifier is the first 4 bytes of the sha3 hash of a canonical form of the function signature
    # details are here: https://github.com/ethereum/wiki/wiki/Ethereum-Contract-ABI
    # we use the eris-abi tool to make this simple:

    # TODO: info messages make it to the output the first time around(if ~/.eris/abi does not exist) They need to go to stderr:
    # for that reason we run the command the second time, until this is fixed. Example: echo $DATA
    # Abi directory tree incomplete... Creating it... Directory tree built! a5f3c23b00000000000000000000000000000000000000000000000000000000000000190000000000000000000000000000000000000000000000000000000000000025

    DATA=`eris-abi pack --input file <(echo $ABI) $FUNCTION $ARGS` 
    DATA=`eris-abi pack --input file <(echo $ABI) $FUNCTION $ARGS` 
    echoerr "DATA~$DATA" 
    echo "$DATA" 
}



verify_result() {
    echo "verify_result()"
    # convert it from hex to int
    RESULT=`echo $((16#$RESULT))`

    echo "$FUNCTION($ARGS) = $RESULT"
    return 0
    
    if [[ "$RESULT" != "$RESULT_EXPECTED" ]]; then
            echo "SMART CONTRACT ADDITION TX FAILED"
            echo "GOT $RESULT"
            echo "EXPECTED $RESULT_EXPECTED"
    else
            echo 'SMART CONTRACT ADDITION TX SUCCEEDED!' 
            echo "$FUNCTION($ARGS) = $RESULT"
    fi
}


##################################################################
## Step 7 - Create and Sign Transaction for Talking to Contract ##
##################################################################
call_contract_w_tran() {
    local pubkey=$1
    echo "call_contract_w_tran(pubkey=$pubkey,data=$DATA)"

    # some variables for the call tx
    FEE=0
    GAS=1000
    AMOUNT=1


    # since we've already shown how to create a transaction, sign it, and send it to the blockchain using curl,  now we do it simply using the mintx tool.
    # the --sign and --broadcast flags ensure the transaction is signed (by the private key associated with --pubkey)
    # and broadcast to the chain. the --wait flag waits until the transaction is confirmed
    read -r -d '' cmd <<EOF
    mintx call --node-addr=$ERISDB_HOST --chainID=$CHAIN_ID --to=$CONTRACT_ADDRESS --amt=$AMOUNT --fee=$FEE --gas=$GAS --data=$DATA --pubkey=$pubkey --sign --broadcast --wait
EOF

    echo "cmd=$cmd"
    local mintx_return=`eval "$cmd"`

    echo "mintx_return=$mintx_return"

    # grab the return value
    RESULT=`echo "$mintx_return" | grep "Return Value:" | awk '{print $3}' | sed 's/^0*//'`
}

##################################################################
## Step 8 - Talk to Contracts Without Creating Transactions     ##
##################################################################
# It is possible to "query" contracts using the /call endpoint.
# Such queries are only "simulated calls", in that there is no transaction (or signature) required, and hence they have no effect on the blockchain state.
call_contract_no_tran() {
    echo "call_contract_no_tran()"
    RESULT=`curl -X GET 'http://'"$ERISDB_HOST"'/call?fromAddress="'"$ADDRESS"'"&toAddress="'"$CONTRACT_ADDRESS"'"&data="'"$DATA"'"' --silent | jq ."result"[1].return|strip_quotes`
}

while getopts "is:d:jgt:p:hXY:" opt; do
    case "$opt" in
        i) do_installs;;  #install software
        s) CHAIN_ID="$OPTARG"; kill_all "$CHAIN_ID" && start_chain "$CHAIN_ID";; #delete $CHAIN_ID directory and re-initialize
        #d) ADDRESS="$OPTARG"; read_contract_code && compile "$ADDRESS" && create_contract_tx && broadcast_tx && wait_for_confirmation && verify_bytecode;; #OPTARG is chain's address, returned by -s 
        d) ADDRESS="$OPTARG"; deploy_contract "$ADDRESS";;
        #t) parse_abi_file "$OPTARG" && format_data "$@" && get_pubkey $ADDRESS && call_contract_w_tran $PUBKEY && verify_result;; #call the contract, creating and committing transaction to the chain.#quotes are a must to be able to pass args with spaces
        #p) parse_abi_file "$OPTARG" && format_data "$@" &&                        call_contract_no_tran && verify_result;; #call the contract, without affecting blockchain state.#quotes are a must to be able to pass args with spaces
        p) call_contract  "$@" ;;
        t) call_contract2  "$@" ;;
        X) read_contract_code && usage;;
        Y) process_args "$@";; #quotes are a must to be able to pass args with spaces
        g) show_genesis;;
        j) show_abi_files;;
        h|*) usage;;
    esac
done

