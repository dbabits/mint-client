#! /bin/bash
set -e

# mct = mint client test

REPO=github.com/eris-ltd/mint-client

cd $GOPATH/src/github.com/eris-ltd/mint-client
echo "********** BUILDING MINT-CLIENT ********"
docker build -t mct_client -f ./DOCKER/linked/DockerfileClient . 

# eris/eris container in which we run the tests
docker run -t --rm -v $GOPATH/src/$REPO:/go/src/$REPO -v /var/run/docker.sock:/var/run/docker.sock --entrypoint bash quay.io/eris/eris /go/src/$REPO/DOCKER/eris-cli/run.sh
