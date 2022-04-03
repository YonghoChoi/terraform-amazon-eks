module "eks_cluster" {
  source = "terraform-aws-modules/eks/aws"

  cluster_name                   = local.name
  cluster_version                = "1.21"
  #  cluster_endpoint_private_access = true
  cluster_endpoint_public_access = true
  enable_irsa                    = true

  cluster_addons = {
    coredns = {
      resolve_conflicts = "OVERWRITE"
    }
    kube-proxy = {}
    vpc-cni    = {
      resolve_conflicts = "OVERWRITE"
    }
  }

  cluster_encryption_config = [
    {
      provider_key_arn = local.kms_key_arn
      resources        = ["secrets"]
    }
  ]

  vpc_id     = local.vpc_id
  subnet_ids = local.private_subnets

  # Extend cluster security group rules
  cluster_security_group_additional_rules = {
    egress_nodes_ephemeral_ports_tcp = {
      description                = "To node 1025-65535"
      protocol                   = "tcp"
      from_port                  = 1025
      to_port                    = 65535
      type                       = "egress"
      source_node_security_group = true
    }
  }

  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
  }

  eks_managed_node_groups = {
    api = {
      min_size       = 1
      max_size       = 10
      desired_size   = 2
      instance_types = ["t3.large"]

      labels = {
        Environment = local.env
        Role        = "api"
        Project     = local.project
      }

#      vpc_security_group_ids = [module.worker_node_sg.security_group_id]

      tags = {
        Environment = local.env
        Terraform   = "true"
        Project     = local.project
      }
    }
  }

  tags = {
    Environment = local.env
    Terraform   = "true"
    Project     = local.project
  }
}

resource "aws_iam_role_policy_attachment" "additional" {
  for_each   = module.eks_cluster.eks_managed_node_groups
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = each.value.iam_role_name
}

module "worker_node_sg" {
  source = "terraform-aws-modules/security-group/aws"

  name        = local.name
  vpc_id      = local.vpc_id

  computed_ingress_with_source_security_group_id = [
    {
      rule                     = "all-tcp"
      source_security_group_id = module.worker_node_sg.security_group_id
    }
  ]
  number_of_computed_ingress_with_source_security_group_id = 1
}