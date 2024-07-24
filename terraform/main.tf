# ----------------------------------------------------------
# ECR
# ----------------------------------------------------------
resource "aws_ecr_repository" "remix_quiz_repo" {
  name                 = "remix-quiz-repo"
  image_tag_mutability = "MUTABLE"
}

# ----------------------------------------------------------
# ECRにDockerイメージをpushする
# ----------------------------------------------------------
resource "null_resource" "remix_quiz_docker" {
  # TODO: コードの変更を検知してDockerイメージをビルドし、ECRにpushする
  # triggers = { always_run = timestamp() }

  provisioner "local-exec" {
    command = "aws ecr get-login-password --region ${var.region} | docker login --username AWS --password-stdin ${var.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  }

  provisioner "local-exec" {
    command = "docker build -f ../Dockerfile.prod --platform=linux/amd64 --no-cache -t ${var.account_id}.dkr.ecr.${var.region}.amazonaws.com/remix-quiz-repo:latest ../"
  }

  provisioner "local-exec" {
    command = "docker push ${var.account_id}.dkr.ecr.${var.region}.amazonaws.com/remix-quiz-repo:latest"
  }
}

# ----------------------------------------------------------
# VPC
# ----------------------------------------------------------
# VPCの作成
resource "aws_vpc" "remix_quiz_vpc" {
  cidr_block           = "172.16.0.0/16"
  enable_dns_support   = true # DNS解決を有効化

  tags = {
    Name = "remix-quiz-vpc-tf"
  }
}

# パブリックサブネットの作成
resource "aws_subnet" "remix_quiz_subnet_1" {
  vpc_id                  = aws_vpc.remix_quiz_vpc.id
  cidr_block              = "172.16.1.0/24"
  availability_zone       = "ap-northeast-1a"

  tags = {
    Name = "remix-quiz-subnet-1-tf"
  }
}

resource "aws_subnet" "remix_quiz_subnet_2" {
  vpc_id                  = aws_vpc.remix_quiz_vpc.id
  cidr_block              = "172.16.2.0/24"
  availability_zone       = "ap-northeast-1c"

  tags = {
    Name = "remix-quiz-subnet-2-tf"
  }
}

# インターネットゲートウェイの作成
resource "aws_internet_gateway" "remix_quiz_igw" {
  vpc_id = aws_vpc.remix_quiz_vpc.id

  tags = {
    Name = "remix-quiz-igw-tf"
  }
}

# ルートテーブルの作成
resource "aws_route_table" "remix_quiz_rtb" {
  vpc_id = aws_vpc.remix_quiz_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.remix_quiz_igw.id
  }

  tags = {
    Name = "remix-quiz-rtb-tf"
  }
}

# サブネットとルートテーブルの関連付け
resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.remix_quiz_subnet_1.id
  route_table_id = aws_route_table.remix_quiz_rtb.id
}
resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.remix_quiz_subnet_2.id
  route_table_id = aws_route_table.remix_quiz_rtb.id
}

# defaultのセキュリティグループにルールを追加
resource "aws_default_security_group" "default" {
  vpc_id      = aws_vpc.remix_quiz_vpc.id

  # インバウンドルール: HTTP
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    protocol        = "-1"
    from_port       = 0
    to_port         = 0
    self            = true
  }

  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
  }

  tags = {
    Name = "remix-quiz-sg-tf"
  }
}

# ----------------------------------------------------------
# ECS
# ----------------------------------------------------------
# ECSクラスタの作成
resource "aws_ecs_cluster" "remix-quiz-cluster" {
  name = "remix-quiz-cluster-tf"
}

# タスク定義
resource "aws_ecs_task_definition" "remix_quiz" {
  family                   = "remix-quiz-task-definition-tf"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024"
  memory                   = "3072"
  execution_role_arn       = "arn:aws:iam::${var.account_id}:role/ecsTaskExecutionRole"

  container_definitions = jsonencode([
    {
      name  = "remix-quiz"
      // image = "767397855647.dkr.ecr.ap-northeast-1.amazonaws.com/remix_quiz:0.0.3"
      image = "${var.account_id}.dkr.ecr.${var.region}.amazonaws.com/remix-quiz-repo:latest"
      cpu   = 0
      portMappings = [
        {
          name          = "remix-quiz-3000-tcp"
          containerPort = 3000
          hostPort      = 3000
          protocol      = "tcp"
          appProtocol   = "http"
        }
      ]
      essential = true
    }
  ])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
}

# サービス作成
resource "aws_ecs_service" "remix_quiz_service" {
  name            = "remix-quiz-service-tf"
  cluster         = aws_ecs_cluster.remix-quiz-cluster.id
  task_definition = aws_ecs_task_definition.remix_quiz.arn
  desired_count   = 1
  launch_type = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.remix_quiz_subnet_1.id, aws_subnet.remix_quiz_subnet_2.id]
    security_groups  = [aws_default_security_group.default.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.remix_quiz_tg.arn
    container_name   = "remix-quiz"
    container_port   = 3000
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_controller {
    type = "ECS"
  }

  platform_version = "LATEST"
  propagate_tags   = "NONE"

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  depends_on = [aws_lb_listener.remix_quiz_alb_listener, aws_ecs_task_definition.remix_quiz]
  force_new_deployment = true
}

# ----------------------------------------------------------
# ALB
# ----------------------------------------------------------
# ALBの作成
resource "aws_lb" "remix_quiz_alb" {
  name               = "remix-quiz-alb-tf"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_default_security_group.default.id]
  subnets            = [aws_subnet.remix_quiz_subnet_1.id, aws_subnet.remix_quiz_subnet_2.id]
}

# ALBターゲットグループの作成
resource "aws_lb_target_group" "remix_quiz_tg" {
  name        = "remix-quiz-tg-tf"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.remix_quiz_vpc.id

  health_check {
    enabled             = true
    interval            = 30
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    healthy_threshold   = 5
    unhealthy_threshold = 2
    matcher             = "200"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ALBリスナーの作成
resource "aws_lb_listener" "remix_quiz_alb_listener" {
  load_balancer_arn = aws_lb.remix_quiz_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.remix_quiz_tg.arn
  }
}
