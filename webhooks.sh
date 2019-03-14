#!/bin/bash

DATA_SOURCD=$1
APP_NS=$( echo $APP_NS | tr 'A-Z' 'a-z' )
APP_WORKLOAD=$( echo $APP_WORKLOAD | tr 'A-Z' 'a-z' )
APP_CONTAINER=$( echo $APP_CONTAINER | tr 'A-Z' 'a-z' )
REPO_TYPE=$( echo $REPO_TYPE | tr 'A-Z' 'a-z' )

# 检查是否为测试消息。dockerhub在添加webhooks条目时会触发测试webhooks消息，以下判断排除此消息。
if [[ $( echo $DATA_SOURCD | jq '.push_data | has("tag")' ) == 'true' && $( echo $DATA_SOURCD | jq '.repository | has("name")' ) == 'true' && $( echo $DATA_SOURCD | jq '.repository | has("namespace")' ) == 'true' ]]; then
        
    # 判断仓库类型

    # Aliyunhub
    if echo $REPO_TYPE | grep -qwi "aliyun" ; then

        echo "当前仓库类型为 $REPO_TYPE"
        IMAGES_TAG=$( echo $DATA_SOURCD | jq -r '.push_data.tag' )
        REPO_NAME=$( echo $DATA_SOURCD | jq -r '.repository.name' )
        REPO_NS=$( echo $DATA_SOURCD | jq -r '.repository.namespace')
        REPO_REGION=$( echo $DATA_SOURCD | jq -r '.repository.region' )
        REPO_FULL_NAME=$( echo $DATA_SOURCD | jq -r '.repository.repo_full_name' )

        IMAGES=$( echo "registry.$REPO_REGION.aliyuncs.com/$REPO_FULL_NAME:$IMAGES_TAG" )

        # 判断镜像标签是否为latest，如果不是latest则直接通过kubectl set进行升级。
        if [ x"${IMAGES_TAG}" != x"latest" ]; then

            echo "镜像标签不为latest,直接进行升级"
            kubectl -n $APP_NS set image $APP_WORKLOAD $APP_CONTAINER=$IMAGES --record
            exit $?
        else
            # 检查镜像拉取策略,对于镜像标签为latest的应用，需要设置镜像拉取策略为Always才能触发重新拉取镜像。
            echo "镜像标签为latest"
            IMAGES_PULL_POLICY=$( kubectl -n $APP_NS get $APP_WORKLOAD -o json | jq -r .spec.template.spec.containers[].imagePullPolicy )

            if [ x"${IMAGES_PULL_POLICY}" == x"Always" ]; then

                echo "镜像拉取策略为Always，添加注释触发滚动升级 "
                # 如果镜像拉取策略是Always，则在.spec.template.metadata.annotations中添加注释用来触发滚动更新。
                kubectl -n $APP_NS get $APP_WORKLOAD -o json | \
                jq --arg images $( echo $IMAGES ) '.spec.template.spec.containers[] += {"image": $images}' | \
                jq --arg time $( date -Iseconds ) '.spec.template.metadata.annotations += {"webhooks/updateTimestamp": $time}' | \
                kubectl -n $APP_NS apply -f -
                exit $?

            else 
                # 如果镜像拉取策略不是Always，则先修改为Always，再在.spec.template.metadata.annotations中添加注释用来触发滚动更新。
                echo "镜像拉取策略不为Always。先替换为Always，再添加注释进行滚动升级 "
                kubectl -n $APP_NS get $APP_WORKLOAD -o json | \
                jq '.spec.template.spec.containers[] += {"imagePullPolicy": "Always"}' | \
                jq --arg images $( echo $IMAGES ) '.spec.template.spec.containers[] += {"image": $images}' | \
                jq --arg time $( date -Iseconds ) '.spec.template.metadata.annotations += {"webhooks/updateTimestamp": $time}' | \
                kubectl -n $APP_NS apply -f -
                exit $?
            fi
        fi
    fi

    # Dockerhub
    if echo $REPO_TYPE | grep -qwi "dockerhub" ; then

        echo "当前仓库类型为 $REPO_TYPE"
        IMAGES_TAG=$( echo $DATA_SOURCD | jq -r '.push_data.tag' )
        REPO_NAME=$( echo $DATA_SOURCD | jq -r '.repository.name' )
        REPO_NS=$( echo $DATA_SOURCD | jq -r '.repository.namespace' )
        REPO_FULL_NAME=$( echo $DATA_SOURCD | jq -r '.repository.repo_name' )

        IMAGES=$( echo "$REPO_FULL_NAME/$IMAGES_TAG" )

        if [ x"${IMAGES_TAG}" != x"latest" ]; then
            echo "镜像标签不为latest,直接进行升级"
            kubectl -n $APP_NS set image $APP_WORKLOAD $APP_CONTAINER=$IMAGES --record
            exit $?
        else
            echo "镜像标签为latest"
            IMAGES_PULL_POLICY=$( kubectl -n $APP_NS get $APP_WORKLOAD -o json | jq -r .spec.template.spec.containers[].imagePullPolicy )

            if [ x"${IMAGES_PULL_POLICY}" == x"Always" ]; then

                echo "镜像拉取策略为Always，添加注释进行滚动升级 "
                kubectl -n $APP_NS get $APP_WORKLOAD -o json | \
                jq --arg images $( echo $IMAGES ) '.spec.template.spec.containers[] += {"image": $images}' | \
                jq --arg time $( date -Iseconds ) '.spec.template.metadata.annotations += {"webhooks/updateTimestamp": $time}' | \
                kubectl -n $APP_NS apply  -f -
                exit $?
            else
                echo "镜像拉取策略不为Always。先替换为Always，再添加注释进行滚动升级 "
                kubectl -n $APP_NS get $APP_WORKLOAD -o json | \
                jq --arg images $( echo $IMAGES ) '.spec.template.spec.containers[] += {"image": $images}' | \
                jq --arg time $( date -Iseconds ) '.spec.template.metadata.annotations += {"webhooks/updateTimestamp": $time}' | \
                jq '.spec.template.spec.containers[] += {"imagePullPolicy": "Always"}' | \
                kubectl -n $APP_NS apply  -f -
                exit $?
            fi
        fi      
    fi

    # custom
    if echo $REPO_TYPE | grep -qwi "custom" ; then

        echo "当前仓库类型为 $REPO_TYPE"
        IMAGES_URL=$( echo $DATA_SOURCD | jq -r '.repository.repo_url' )
        IMAGES_NS=$( echo $DATA_SOURCD | jq -r '.repository.namespace' )
        IMAGES_NAME=$( echo $DATA_SOURCD | jq -r '.repository.name' )
        IMAGES_TAG=$( echo $DATA_SOURCD | jq -r '.push_data.tag' )

        IMAGES=$( echo "$IMAGES_URL/$IMAGES_NS/$IMAGES_NAME:$IMAGES_TAG" )

        if [ x"${IMAGES_TAG}" != x"latest" ]; then
            echo "镜像标签不为latest,直接进行升级"
            kubectl -n $APP_NS set image $APP_WORKLOAD $APP_CONTAINER=$IMAGES --record
            exit $?
        else
            echo "镜像标签为latest"
            IMAGES_PULL_POLICY=$( kubectl -n $APP_NS get $APP_WORKLOAD -o json | jq -r .spec.template.spec.containers[].imagePullPolicy )

            if [ x"${IMAGES_PULL_POLICY}" == x"Always" ]; then

                echo "镜像拉取策略为Always，添加注释进行滚动升级 "
                kubectl -n $APP_NS get $APP_WORKLOAD -o json | \
                jq --arg images $( echo $IMAGES ) '.spec.template.spec.containers[] += {"image": $images}' | \
                jq --arg time $( date -Iseconds ) '.spec.template.metadata.annotations += {"webhooks/updateTimestamp": $time}' | \
                kubectl -n $APP_NS apply  -f -
                exit $?
            else
                echo "镜像拉取策略不为Always。先替换为Always，再添加注释进行滚动升级 "
                kubectl -n $APP_NS get $APP_WORKLOAD -o json | \
                jq '.spec.template.spec.containers[] += {"imagePullPolicy": "Always"}' | \
                jq --arg images $( echo $IMAGES ) '.spec.template.spec.containers[] += {"image": $images}' | \
                jq --arg time $( date -Iseconds ) '.spec.template.metadata.annotations += {"webhooks/updateTimestamp": $time}' | \
                kubectl -n $APP_NS apply  -f -
                exit $?
            fi
        fi      
    fi

    echo "$REPO_TYPE 为不支持的仓库类型"
    exit $?
fi