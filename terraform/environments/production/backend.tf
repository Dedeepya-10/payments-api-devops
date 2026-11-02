terraform {
  backend "s3" {
    bucket         = "payments-api-tfstate" # created by terraform/bootstrap
    key            = "payments-api/production/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "payments-api-tfstate-lock"
    encrypt        = true
  }
}
