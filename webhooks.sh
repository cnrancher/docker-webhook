#!/bin/bash

if [ x"${TAG}" != x"latest" ]; then

    kubectl -n $NS set image $WORKLOAD $CONTAINER=registry.$REGION.aliyuncs.com/$REPO_FULL_NAME:$TAG --record

else

    IMAGES_PULL_POLICY=$(kubectl -n $NS get $WORKLOAD -o json | jq -r .spec.template.spec.containers[].imagePullPolicy)

    if [ x"${IMAGES_PULL_POLICY}" == x"Always" ]; then
        
        kubectl -n $NS get $WORKLOAD -o json | jq --arg time $(date -Iseconds) '.spec.template.metadata += {"updateTimestamp": $time}' | kubectl -n $NS apply  -f -

    else

        kubectl -n $NS get $WORKLOAD -o json | \
        jq --arg time $(date -Iseconds) '.spec.template.metadata += {"updateTimestamp": $time}' | \
        jq '.spec.template.spec.containers[] += {"imagePullPolicy": "Always"}'| \
        kubectl -n $NS apply  -f -
    fi

fi
