
# path in the GOPATH
export base=github.com/eris-ltd/mint-client

# scripts for building containers and running dependency containers
export build_script=DOCKER/linked/build.sh

# we use this for building and running the base
export docker_latest="1.8.2"

# we want this repo to trigger integration tests when we push to "staging"
export integration_tests_branch=staging
