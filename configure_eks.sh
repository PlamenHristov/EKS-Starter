#!/bin/bash

createRole() {
    aws cloudformation create-stack \
	--stack-name eks-service-role \
	--template-body file://./config/eks/amazon-eks-service-role.yaml \
	--capabilities CAPABILITY_NAMED_IAM

    waitCreateStack eks-service-role
}

deployBastionBox(){

 aws cloudformation create-stack \
	--stack-name $BASTION_STACK_NAME  \
	--template-body https://aws-quickstart.s3.amazonaws.com/quickstart-linux-bastion/templates/linux-bastion.template \
    --capabilities CAPABILITY_IAM \
    --parameters \
	    ParameterKey=VPCID,ParameterValue=${EKS_VPC_ID} \
        ParameterKey=PublicSubnet1ID,ParameterValue=$(cut -d',' -f1 <<<$EKS_SUBNET_IDS) \
	    ParameterKey=PublicSubnet2ID,ParameterValue=$(cut -d',' -f2 <<<$EKS_SUBNET_IDS) \
	    ParameterKey=RemoteAccessCIDR,ParameterValue=${TRUSTED_CIDR_BLOCK} \
	    ParameterKey=KeyPairName,ParameterValue=${WORKER_STACK_NAME} \
	    ParameterKey=EnableTCPForwarding,ParameterValue=true \
	    ParameterKey=EnableX11Forwarding,ParameterValue=true \
	    ParameterKey=EnableBanner,ParameterValue=true

 waitCreateStack $BASTION_STACK_NAME

  #allow ssh to cluster. Assumes one security group and all instances have the same security group setup
  EKS_NODE_SECURITY_GROUP=$(getStackOutput  $WORKER_STACK_NAME NodeInstanceRole)
  EC2_SECURITY_GROUP=$(getStackOutput  $WORKER_STACK_NAME NodeSecurityGroup)


  aws ec2 authorize-security-group-ingress --group-id $EC2_SECURITY_GROUP --protocol tcp --port 22 --cidr $EKS_VPC_CIDR

}

getStackOutput() {
    declare desc=""
    declare stack=${1:?required stackName} outputKey=${2:? required outputKey}

    aws cloudformation describe-stacks \
	--stack-name $stack \
	--query 'Stacks[].Outputs[? OutputKey==`'$outputKey'`].OutputValue' \
	--out textre
    
}

createCluster() {
   aws eks create-cluster \
       --name $EKS_CLUSTER_NAME \
       --role-arn $EKS_SERVICE_ROLE \
       --resources-vpc-config subnetIds=$EKS_SUBNET_IDS,securityGroupIds=$EKS_SECURITY_GROUPS

   #wait for "ACTIVE"
   

    echo "---> wait for create cluster: $EKS_CLUSTER_NAME ..."
    while ! aws eks describe-cluster --name $EKS_CLUSTER_NAME  --query cluster.status --out text | grep -q ACTIVE; do 
	sleep ${SLEEP:=3}
	echo -n .
    done



}
createVPC() {
  aws cloudformation create-stack \
    --stack-name ${VPC_STACK_NAME} \
    --template-body https://amazon-eks.s3-us-west-2.amazonaws.com/cloudformation/2019-01-09/amazon-eks-vpc-sample.yaml \
    --region ${AWS_DEFAULT_REGION}

    waitCreateStack ${VPC_STACK_NAME}
}


installAwsEksCli() {
    curl -LO https://s3-us-west-2.amazonaws.com/amazon-eks/1.10.3/2018-06-05/eks-2017-11-01.normal.json
    mkdir -p $HOME/.aws/models/eks/2017-11-01/
    mv eks-2017-11-01.normal.json $HOME/.aws/models/eks/2017-11-01/
    aws configure add-model  --service-name eks --service-model file://$HOME/.aws/models/eks/2017-11-01/eks-2017-11-01.normal.json
}

createKubeConfig() {
  echo "---> creatin kubeconfig file: ~/.kube/config-eks"
  cat >  ~/.kube/config-eks <<EOF
apiVersion: v1
clusters:
- cluster:
    server: ${EKS_ENDPOINT}
    certificate-authority-data: ${EKS_CERT}
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: aws
  name: aws
current-context: aws
kind: Config
preferences: {}
users:
- name: aws
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1alpha1
      command: aws-iam-authenticator
      args:
        - "token"
        - "-i"
        - "${EKS_CLUSTER_NAME}"
EOF

  export KUBECONFIG=$KUBECONFIG:~/.kube/config-eks
}

createWorkers() {

    if ! aws ec2 describe-key-pairs --key-names  ${WORKER_STACK_NAME}; then
      aws ec2 create-key-pair --key-name ${WORKER_STACK_NAME} --query 'KeyMaterial' --output text > $HOME/.ssh/id-eks.pem
      chmod 0400 $HOME/.ssh/id-eks.pem
      aws ec2 wait key-pair-exists --key-names ${WORKER_STACK_NAME}
    fi

    aws cloudformation create-stack \
	--stack-name $WORKER_STACK_NAME  \
	--template-body https://amazon-eks.s3-us-west-2.amazonaws.com/cloudformation/2019-01-09/amazon-eks-nodegroup.yaml \
        --capabilities CAPABILITY_IAM \
        --parameters \
	    ParameterKey=NodeInstanceType,ParameterValue=${EKS_NODE_TYPE} \
	    ParameterKey=NodeImageId,ParameterValue=${EKS_WORKER_AMI} \
	    ParameterKey=NodeGroupName,ParameterValue=${EKS_NODE_GROUP_NAME} \
	    ParameterKey=NodeAutoScalingGroupMinSize,ParameterValue=${EKS_NODE_MIN} \
	    ParameterKey=NodeAutoScalingGroupDesiredCapacity,ParameterValue=${EKS_DESIRED_NODES} \
	    ParameterKey=NodeAutoScalingGroupMaxSize,ParameterValue=${EKS_NODE_MAX} \
	    ParameterKey=ClusterControlPlaneSecurityGroup,ParameterValue=${EKS_SECURITY_GROUPS} \
	    ParameterKey=ClusterName,ParameterValue=${EKS_CLUSTER_NAME} \
	    ParameterKey=Subnets,ParameterValue=${EKS_SUBNET_IDS//,/\\,} \
	    ParameterKey=VpcId,ParameterValue=${EKS_VPC_ID} \
	    ParameterKey=KeyName,ParameterValue=${WORKER_STACK_NAME}

    waitCreateStack ${WORKER_STACK_NAME}
}

configureAutoScaling() {
  cat > ./config/autoscaler/k8s-asg-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup"
      ],
      "Resource": "*"
    }
  ]
}
EOF

#  ROLE_NAME=$(getStackOutput  $WORKER_STACK_NAME NodeInstanceRole | cut -d'/' -f2)
#  aws iam put-role-policy --role-name $ROLE_NAME --policy-name ASG-Policy-For-Worker --policy-document file://./config/autoscaler/k8s-asg-policy.json

  AUTO_SCALING_GROUP=$(aws ec2 describe-instances |  jq -r '.Reservations[0]["Instances"][0]["Tags"] | .[] | select(.Key=="aws:autoscaling:groupName") | .Value')
  cat ./config/autoscaler/cluster_autoscaler.yml |
  sed 's/<AUTOSCALING_GROUP_NAME>/'"$AUTO_SCALING_GROUP"'/g' |
  sed 's/<AWS_REGION>/'"$AWS_DEFAULT_REGION"'/g' |
  sed 's/<MIN_NODES>/'"$EKS_NODE_MIN"'/g' |
  sed 's/<MAX_NODES>/'"$EKS_NODE_MAX"'/g' |
  kubectl create -f -
}

authWorkers() {
    EKS_INSTANCE_ROLE=$(getStackOutput  $WORKER_STACK_NAME NodeInstanceRole)
    cat > ./config/eks/aws-auth-cm.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
data:
  mapRoles: |
    - rolearn: ${EKS_INSTANCE_ROLE}
      username: system:node:{{EC2PrivateDNSName}}
      groups:
        - system:bootstrappers
        - system:nodes
EOF
    kubectl apply -f ./config/eks/aws-auth-cm.yaml
}

waitStackState() {
    declare desc=""
    declare stack=${1:? required stackName} state=${2:? required stackStatePattern}
    
    echo "---> wait for stack delete: ${stack}"
    while ! aws cloudformation describe-stacks --stack-name ${stack} --query  Stacks[].StackStatus --out text | grep -q "${state}"; do 
	sleep ${SLEEP:=3}
	echo -n .
    done

}

waitCreateStack() {
    declare stack=${1:? required stackName}
    echo "---> wait for stack create: ${stack} ..."
    aws cloudformation wait stack-create-complete --stack-name $stack
}

deleteStackWait() {
    declare stack=${1:? required stackName}
    aws cloudformation delete-stack --stack-name $stack
    echo "---> wait for stack delete: ${stack} ..."
    aws cloudformation wait stack-delete-complete --stack-name $stack
}

eksCleanup() {
    deleteStackWait $WORKER_STACK_NAME
    aws eks delete-cluster --name $EKS_CLUSTER_NAME
    deleteStackWait $VPC_STACK_NAME
}

eksCreateCluster() {

  export AWS_DEFAULT_REGION=us-east-2
  export EKS_WORKER_AMI=ami-0c2e8d28b1f854c68
  export VPC_STACK_NAME=eks-service-vpc
  export WORKER_STACK_NAME=eks-service-worker-nodes
  export EKS_CLUSTER_NAME=eks-devel
  export EKS_SERVICE_ROLE_NAME=eksServiceRole
  export BASTION_STACK_NAME=eks-service-bastion
  export TRUSTED_CIDR_BLOCK=0.0.0.0/0
  export EKS_NODE_GROUP_NAME=eks-worker-group
  export EKS_NODE_TYPE=m4.large
  export EKS_NODE_MIN=5
  export EKS_DESIRED_NODES=15
  export EKS_NODE_MAX=30
  
  
  if ! aws iam get-role --role-name $EKS_SERVICE_ROLE_NAME > /dev/null ; then
      createRole
  fi

  EKS_SERVICE_ROLE=$(aws iam list-roles --query 'Roles[?contains(RoleName, `eksService`) ].Arn' --out text)

  createVPC

  EKS_SECURITY_GROUPS=$(getStackOutput $VPC_STACK_NAME SecurityGroups)
  EKS_VPC_ID=$(getStackOutput $VPC_STACK_NAME VpcId)
  EKS_VPC_CIDR=$(aws ec2 describe-vpcs --vpc-id $EKS_VPC_ID | jq -r '.Vpcs[0]["CidrBlockAssociationSet"][0]["CidrBlock"]')
  EKS_SUBNET_IDS=$(getStackOutput $VPC_STACK_NAME SubnetIds)

  createCluster

  EKS_ENDPOINT=$(aws eks describe-cluster --name $EKS_CLUSTER_NAME --query cluster.endpoint)
  EKS_CERT=$(aws eks describe-cluster --name $EKS_CLUSTER_NAME --query cluster.certificateAuthority.data)

  echo $EKS_ENDPOINT
  echo $EKS_CERT
  createWorkers


  createKubeConfig
  authWorkers
  configureAutoScaling
  deployBastionBox
}
eksCreateCluster
