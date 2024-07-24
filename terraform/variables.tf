variable "region" {
  description = "The region where resources should be created"
  type        = string
  default     = "ap-northeast-1"
}

variable "account_id" {
  type        = string
  default     = "767397855647"
}

variable "image_name" {
  type        = string
  default     = "remix-quiz"
}