variable "environment" {
  type    = string
  default = "staging"
}

variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "vpc_cidr_block" {
  type    = string
  default = "10.1.0.0/16"
}

variable "image" {
  description = "Container image, e.g. ghcr.io/org/payments-api:sha-abc123"
  type        = string
}

variable "container_port" {
  type    = number
  default = 8080
}

variable "task_cpu" {
  type    = number
  default = 256
}

variable "task_memory" {
  type    = number
  default = 512
}

variable "desired_count" {
  type    = number
  default = 1
}

variable "max_count" {
  type    = number
  default = 3
}

variable "log_retention_days" {
  type    = number
  default = 14
}
