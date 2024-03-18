terraform {
  backend "s3" {
    region = "us-east-1"
    bucket = "backendvedro"
    key    = "project-tf-statefile"
  }

}