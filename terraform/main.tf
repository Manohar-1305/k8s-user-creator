provider "aws" {
  region = "ap-south-1"
}

resource "aws_vpc" "prod_vpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "prod-VPC"
  }
}

data "aws_availability_zones" "available" {}

resource "aws_subnet" "prod_subnet" {
  vpc_id                  = aws_vpc.prod_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = data.aws_availability_zones.available.names[0]

  tags = {
    Name = "prod-Public-1"
  }
}

resource "aws_internet_gateway" "prod_igw" {
  vpc_id = aws_vpc.prod_vpc.id

  tags = {
    Name = "prod-IGW"
  }
}

resource "aws_route_table" "prod_rt" {
  vpc_id = aws_vpc.prod_vpc.id

  tags = {
    Name = "prod-Public-RT"
  }
}

resource "aws_route" "internet_access" {
  route_table_id         = aws_route_table.prod_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.prod_igw.id
}

resource "aws_route_table_association" "prod_subnet_assoc" {
  subnet_id      = aws_subnet.prod_subnet.id
  route_table_id = aws_route_table.prod_rt.id
}

resource "aws_security_group" "prod_sg" {
  vpc_id = aws_vpc.prod_vpc.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "prod-SG"
  }
}

resource "aws_instance" "mysql-server" {
  ami                    = "ami-03bb6d83c60fc5f7c"
  instance_type          = "t2.medium"
  key_name               = "testing-dev-1"
  subnet_id              = aws_subnet.prod_subnet.id
  vpc_security_group_ids = [aws_security_group.prod_sg.id]
  user_data              = file("user_banner.sh")

  # # Set root volume size to 25GB
  # root_block_device {
  #   volume_size           = 25
  #   volume_type           = "gp3"
  #   delete_on_termination = true
  # }

  tags = {
    Name = "mysql-server"
  }
}

resource "aws_instance" "app-server" {
  ami                    = "ami-03bb6d83c60fc5f7c"
  instance_type          = "t2.medium"
  key_name               = "testing-dev-1"
  subnet_id              = aws_subnet.prod_subnet.id
  vpc_security_group_ids = [aws_security_group.prod_sg.id]
  user_data              = file("user_banner.sh")

  tags = {
    Name = "app-server"
  }
}

#Outputs
output "mysql_server_public_ip" {
  value = aws_instance.mysql-server.public_ip
}

output "app_server_public_ip" {
  value = aws_instance.app-server.public_ip
}
