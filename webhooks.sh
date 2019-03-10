#!/bin/bash

kubectl -n $NS set image $WORKLOAD $CONTAINER=registry.$REGION.aliyuncs.com/$REPO_FULL_NAME:$TAG --record


