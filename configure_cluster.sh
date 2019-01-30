#!/usr/bin/env bash

configureCassandra(){
    kubectl apply -f ./config/cassandra/cassandra_configmap.yaml
    kubectl apply -f ./config/cassandra/cassandra-service.yaml
    kubectl apply -f ./config/cassandra/cassandra-statefulset.yaml
    kubectl apply -f ./config/cassandra/local-volumes.yaml
}

cleanUpCassandra(){
grace=$(kubectl get po cassandra-0 -o=jsonpath='{.spec.terminationGracePeriodSeconds}') \
  && kubectl delete statefulset -l app=cassandra \
  && echo "Sleeping $grace" \
  && sleep $grace \
  && kubectl delete pvc -l app=cassandra
  kubectl delete service -l app=cassandra
}

configureHelm(){
    # Helm config
    kubectl -n kube-system delete deployment tiller-deploy
    kubectl -n kube-system delete service/tiller-deploy
    helm init --upgrade --service-account tiller
}
configureDashboard(){
    # https://github.com/aws/amazon-vpc-cni-k8s/issues/59
    # Upgrade cni addon to resolve dns issues
    kubectl apply -f https://raw.githubusercontent.com/aws/amazon-vpc-cni-k8s/master/config/v1.3/aws-k8s-cni.yaml
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/dashboard/v1.10.1/src/deploy/recommended/kubernetes-dashboard.yaml
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/heapster/master/deploy/kube-config/influxdb/heapster.yaml
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/heapster/master/deploy/kube-config/influxdb/influxdb.yaml
    kubectl apply -f https://raw.githubusercontent.com/kubernetes/heapster/master/deploy/kube-config/rbac/heapster-rbac.yaml
}
configureKafka(){
    kubectl apply -f ./kubernetes-kafka/configure/aws-storageclass-broker-gp2.yml
    kubectl apply -f ./kubernetes-kafka/configure/aws-storageclass-zookeeper-gp2.yml
    kubectl apply -f ./kubernetes-kafka/00-namespace.yml
    kubectl apply -f ./kubernetes-kafka/rbac-namespace-default/
    kubectl apply -f ./kubernetes-kafka/zookeeper
    kubectl apply -f ./kubernetes-kafka/kafka
}
configureCluster(){
    kubectl apply -f ./config/eks/eks-admin-service-account.yaml

}
configureRedis() {
    kubectl create -f ./config/redis/redis-master.yaml
    kubectl create -f ./config/redis/redis-sentinel-service.yaml
    kubectl create -f ./config/redis/redis-controller.yaml
    kubectl create -f ./config/redis/redis-sentinel-controller.yaml
}

openProxtAndGetDashSecret(){
#kubectl -n kube-system describe secret $(kubectl -n kube-system get secret | grep eks-admin | awk '{print $1}')
#kubectl proxy
}

all (){
    configureCluster
    configureHelm
    configureDashboard
    configureCassandra
    configureKafka
    configureRedis
}
all