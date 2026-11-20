"""AWS side of .github/scripts/terraform-e2e.sh, run with boto3 inside the moto
container (docker exec -i <moto> python3 - <command> ... < this file).

  tag BUCKET ACCOUNT TAGS_JSON   give the bucket the tags Terraform planned
  applied BUCKET OIDC_ARN T...   what the apply created, read back through the APIs
  seed BUCKET TENANT             leave a cache object, as a job would
  destroyed                      nothing of the fleet is left
"""

import json
import sys

import boto3

# "moto" resolves inside the container as on the kind network, and so does
# "<account>.moto", the host S3 Control calls. TLS is verified against the
# test's throwaway CA.
KW = dict(endpoint_url="https://moto:5000", region_name="us-east-1", verify="/tls/ca.crt",
          aws_access_key_id="moto", aws_secret_access_key="moto")
s3 = boto3.client("s3", **KW)
iam = boto3.client("iam", **KW)


def check(ok, what):
    if not ok:
        sys.exit(f"FAIL: {what}")
    print(f"ok: {what}")


def tag(bucket, account, tags):
    # The provider sends the bucket's tags inside CreateBucket, which AWS
    # applies and moto ignores; it reads them back through S3 Control.
    tags = json.loads(tags)
    boto3.client("s3control", **KW).tag_resource(
        AccountId=account, ResourceArn=f"arn:aws:s3:::{bucket}", Tags=tags)
    print("cache bucket tags as AWS would hold them:", ", ".join(f"{t['Key']}={t['Value']}" for t in tags))


def applied(bucket, oidc_arn, *tenants):
    pab = s3.get_public_access_block(Bucket=bucket)["PublicAccessBlockConfiguration"]
    check(all(pab.values()) and len(pab) == 4, f"{bucket}: all four public access blocks on")
    rule = s3.get_bucket_encryption(Bucket=bucket)["ServerSideEncryptionConfiguration"]["Rules"][0]
    check(rule["ApplyServerSideEncryptionByDefault"]["SSEAlgorithm"] == "AES256", f"{bucket}: SSE-S3 by default")
    owner = s3.get_bucket_ownership_controls(Bucket=bucket)["OwnershipControls"]["Rules"][0]["ObjectOwnership"]
    check(owner == "BucketOwnerEnforced", f"{bucket}: ACLs disabled (BucketOwnerEnforced)")
    life = s3.get_bucket_lifecycle_configuration(Bucket=bucket)["Rules"]
    check(any(r["Status"] == "Enabled" and r["Expiration"]["Days"] == 14 for r in life), f"{bucket}: objects expire after 14 days")
    deny = json.loads(s3.get_bucket_policy(Bucket=bucket)["Policy"])["Statement"]
    check(any(s["Effect"] == "Deny" and s["Condition"]["Bool"]["aws:SecureTransport"] == "false" for s in deny),
          f"{bucket}: policy denies plain HTTP")

    for t in tenants:
        role = iam.get_role(RoleName=f"e2e-runner-{t}")["Role"]
        trust = role["AssumeRolePolicyDocument"]
        trust = json.loads(trust) if isinstance(trust, str) else trust
        stmt = trust["Statement"][0]
        subs = [v for k, v in stmt["Condition"]["StringEquals"].items() if k.endswith(":sub")]
        check(stmt["Principal"]["Federated"] == oidc_arn and subs == [f"system:serviceaccount:ci-{t}:gitlab-runner"],
              f"role e2e-runner-{t}: assumable only through the cluster's OIDC provider by ci-{t}/gitlab-runner")
        doc = iam.get_role_policy(RoleName=f"e2e-runner-{t}", PolicyName="runner-cache")["PolicyDocument"]
        doc = json.loads(doc) if isinstance(doc, str) else doc
        objects = [s for s in doc["Statement"] if s.get("Sid") == "ReadWriteOwnPrefix"][0]["Resource"]
        check(objects == f"arn:aws:s3:::{bucket}/{t}/*", f"role e2e-runner-{t}: objects only under {t}/")


def seed(bucket, tenant):
    # moto applies bucket policies without their conditions, so the module's
    # deny-unless-TLS statement refuses every write, TLS or not. Lift the
    # policy for the one write and put the same document back, unchanged.
    policy = s3.get_bucket_policy(Bucket=bucket)["Policy"]
    s3.delete_bucket_policy(Bucket=bucket)
    try:
        s3.put_object(Bucket=bucket, Key=f"{tenant}/project/1/default/cache.zip", Body=b"cache")
    finally:
        s3.put_bucket_policy(Bucket=bucket, Policy=policy)
    check(s3.get_bucket_policy(Bucket=bucket)["Policy"] == policy, f"{bucket}: policy restored as it was")
    print(f"left s3://{bucket}/{tenant}/project/1/default/cache.zip behind")


def destroyed():
    buckets = [b["Name"] for b in s3.list_buckets().get("Buckets", [])]
    check(not buckets, f"no buckets left {buckets or ''}".rstrip())
    roles = [r["RoleName"] for r in iam.list_roles()["Roles"] if r["RoleName"].startswith("e2e-")]
    check(not roles, f"no runner roles left {roles or ''}".rstrip())
    oidc = iam.list_open_id_connect_providers()["OpenIDConnectProviderList"]
    check(not oidc, "no OIDC provider left")


if __name__ == "__main__":
    {"tag": tag, "applied": applied, "seed": seed, "destroyed": destroyed}[sys.argv[1]](*sys.argv[2:])
