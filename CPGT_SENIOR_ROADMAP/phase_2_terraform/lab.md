-Recreate EC2 setups from phase 1 using terraform
-paramterize it (vars for region, instance type)
- use terraform plan -> apply -> destroy
- store terraform state in s3

deliverable:
    infra-as-code-terraform-ec2




-----------------------------------------
Infra from lab 1:
    vpc
    subnet
    igw
    route table
    ec2 instance (t2.micro)

    ssh with keypair, deploy with  nginx, serve static page

----------------------------------------

Terraform setup in project dir
    /terraform
        -main.tf 
            this is where we define core infra (vpc,subnets...)
            you define desired state here.

        -outputs.tf 
            stuff terraform prints after apply/destroy
            other modules and tools can read this too.
            
            purpose of outputs is to save you from 
            using aws ... describe fishing

        -variables.tf
            where we define env var values

        -provider.tf
            where we define the cloud provider for terraform to use to build
            our infra.



how to use outputs
    terraform output
    terraform output -raw http_url
    terraform output -raw ssh_command



Using defined aws role for terraform

    specify profile to use in variabled.tf


verify what aws profile you are in in cli - before running tf

    aws sts get-caller-identity --profile terraform


to get access key for role (if dont have already)
    login to web mgmt console
    nav to user -> should see terraform-deployer user
    create access key, download and store


    store account and credentials to aws profiles list (if not already there)
    
        aws configure --profile terraform_deployer → put a card in your wallet (profile saved).

    set specific profile to be used for duration of 
    terminal session

        export AWS_PROFILE=terraform_deployer → swipe that card at the checkout (choose which one is active right now).



the ssh command will be printed from outputs.tf
using this, we will be able to login to the instance

public ip also given from output

open http:// <that ip or DNS>


SUCCESS!


IMPORTANT ***

Sec group must have 
    ingress {
        from_port   = 80
        to_port     = 80
        protocol    = "tcp"
        cidr_blocks = ["0.0.0.0/0"]
    }
