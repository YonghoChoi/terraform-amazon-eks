resource "null_resource" "cluster_autoscaler" {
  depends_on = [module.eks_cluster]
  triggers = {
    eks_cluster_name = module.eks_cluster.cluster_id
    profile          = local.aws_credential["profile"]
    region           = local.aws_credential["region"]
    account_id       = local.aws_credential["account_id"]
  }
  provisioner "local-exec" {
    when    = create
    command = <<EOT
set -e
WORKDIR=./workspace/cluster_autoscaler

aws eks update-kubeconfig --name ${self.triggers.eks_cluster_name} \
  --profile ${self.triggers.profile} \
  --region ${self.triggers.region}

eksctl utils associate-iam-oidc-provider \
  --cluster ${self.triggers.eks_cluster_name} \
  --profile ${self.triggers.profile} \
  --region ${self.triggers.region} \
  --approve

mkdir -p $WORKDIR
cat <<EoF > $WORKDIR/k8s-asg-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": [
                "autoscaling:DescribeAutoScalingGroups",
                "autoscaling:DescribeAutoScalingInstances",
                "autoscaling:DescribeLaunchConfigurations",
                "autoscaling:DescribeTags",
                "autoscaling:SetDesiredCapacity",
                "autoscaling:TerminateInstanceInAutoScalingGroup",
                "ec2:DescribeLaunchTemplateVersions"
            ],
            "Resource": "*",
            "Effect": "Allow"
        }
    ]
}
EoF

aws iam create-policy   \
  --policy-name ${self.triggers.eks_cluster_name}-k8s-asg-policy \
  --policy-document file://$WORKDIR/k8s-asg-policy.json

eksctl create iamserviceaccount \
  --name cluster-autoscaler \
  --namespace kube-system \
  --cluster ${self.triggers.eks_cluster_name} \
  --profile ${self.triggers.profile} \
  --region ${self.triggers.region} \
  --attach-policy-arn "arn:aws:iam::${self.triggers.account_id}:policy/${self.triggers.eks_cluster_name}-k8s-asg-policy" \
  --approve \
  --override-existing-serviceaccounts

curl -o $WORKDIR/cluster-autoscaler-autodiscover.yaml https://raw.githubusercontent.com/kubernetes/autoscaler/master/cluster-autoscaler/cloudprovider/aws/examples/cluster-autoscaler-autodiscover.yaml
sed "s/<YOUR CLUSTER NAME>/${self.triggers.eks_cluster_name}/g" $WORKDIR/cluster-autoscaler-autodiscover.yaml > $WORKDIR/cluster-autoscaler.yaml
kubectl apply -f $WORKDIR/cluster-autoscaler.yaml
kubectl -n kube-system \
    annotate deployment.apps/cluster-autoscaler \
    cluster-autoscaler.kubernetes.io/safe-to-evict="false"
rm -rf $WORKDIR
EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
set -e
WORKDIR=./workspace/cluster_autoscaler
CLUSTER_NAME=${self.triggers.eks_cluster_name}
ACCOUNT_ID=${self.triggers.account_id}
PROFILE=${self.triggers.profile}
REGION=${self.triggers.region}

kubectl delete -f https://raw.githubusercontent.com/kubernetes/autoscaler/master/cluster-autoscaler/cloudprovider/aws/examples/cluster-autoscaler-autodiscover.yaml || true

eksctl delete iamserviceaccount \
  --name cluster-autoscaler \
  --namespace kube-system \
  --cluster ${self.triggers.eks_cluster_name} \
  --profile ${self.triggers.profile} \
  --region ${self.triggers.region} || true

aws iam delete-policy   \
  --policy-arn "arn:aws:iam::${self.triggers.account_id}:policy/${self.triggers.eks_cluster_name}-k8s-asg-policy" || true
EOT
  }
}

resource "null_resource" "load_balancer_controller" {
  depends_on = [module.eks_cluster]
  triggers = {
    eks_cluster_name = module.eks_cluster.cluster_id
    profile          = local.aws_credential["profile"]
    region           = local.aws_credential["region"]
    account_id       = local.aws_credential["account_id"]
    version          = "2.3.0"
  }
  provisioner "local-exec" {
    when    = create
    command = <<EOT
WORKDIR=./workspace/load_balancer_controller
VERSION=${self.triggers.version}

aws eks update-kubeconfig --name ${self.triggers.eks_cluster_name} \
  --profile ${self.triggers.profile} \
  --region ${self.triggers.region}

mkdir -p $WORKDIR
curl -o $WORKDIR/iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v${self.triggers.version}/docs/install/iam_policy.json
aws iam create-policy \
    --policy-name AWSLoadBalancerControllerIAMPolicy-${self.triggers.eks_cluster_name} \
    --policy-document file://$WORKDIR/iam_policy.json

eksctl create iamserviceaccount \
  --cluster=${self.triggers.eks_cluster_name} \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --profile=${self.triggers.profile} \
  --region=${self.triggers.region} \
  --attach-policy-arn=arn:aws:iam::${self.triggers.account_id}:policy/AWSLoadBalancerControllerIAMPolicy-${self.triggers.eks_cluster_name} \
  --override-existing-serviceaccounts \
  --approve

kubectl apply \
    --validate=false \
    -f https://github.com/jetstack/cert-manager/releases/download/v1.5.4/cert-manager.yaml

kubectl wait deployment/cert-manager-webhook -n cert-manager --for condition=available

VERSION_UNDERBAR=`echo ${self.triggers.version} | sed "s/\./_/g"`
VERSION_NAME=$VERSION_UNDERBAR'_full'
echo https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases/download/v${self.triggers.version}/v$VERSION_NAME.yaml
curl -Lo $WORKDIR/v$VERSION_NAME.yaml "https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases/download/v${self.triggers.version}/v$VERSION_NAME.yaml"
sed "s/your-cluster-name/${self.triggers.eks_cluster_name}/g" $WORKDIR/v$VERSION_NAME.yaml > $WORKDIR/loadbalancer_controller.yaml
kubectl apply --validate=false -f $WORKDIR/loadbalancer_controller.yaml
rm -rf $WORKDIR
EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<EOT
WORKDIR=./workspace/load_balancer_controller

aws eks update-kubeconfig --name ${self.triggers.eks_cluster_name} \
  --profile ${self.triggers.profile} \
  --region ${self.triggers.region}

VERSION_UNDERBAR=`echo ${self.triggers.version} | sed "s/\./_/g"`
kubectl delete -f https://github.com/jetstack/cert-manager/releases/download/v1.5.4/cert-manager.yaml || true
kubectl delete -f https://github.com/kubernetes-sigs/aws-load-balancer-controller/releases/download/v${self.triggers.version}/v$VERSION_UNDERBAR_full.yaml || true

eksctl delete iamserviceaccount \
  --cluster=${self.triggers.eks_cluster_name} \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --profile=${self.triggers.profile} \
  --region=${self.triggers.region} || true

aws iam delete-policy \
    --policy-arn arn:aws:iam::${self.triggers.account_id}:policy/AWSLoadBalancerControllerIAMPolicy-${self.triggers.eks_cluster_name} || true
EOT
  }
}
