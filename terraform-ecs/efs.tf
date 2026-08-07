# One filesystem, three access points — one per uid/gid Copilot's manifests used
# (10000 = ui, 10001 = metrics/qdrant, 10002 = server's shared config).
resource "aws_efs_file_system" "this" {
  creation_token = "${local.name_prefix}-efs"
  encrypted      = true

  tags = merge(local.tags, { Name = "${local.name_prefix}-efs" })
}

resource "aws_efs_mount_target" "this" {
  # Keyed by static index, not by subnet ID: private_subnets' length is known at plan time
  # (fixed at 2 in vpc.tf), but the actual subnet IDs aren't known until the VPC is created,
  # so a for_each keyed on the IDs themselves fails plan-time evaluation for a brand-new VPC.
  for_each = toset([for idx in range(length(module.vpc.private_subnets)) : tostring(idx)])

  file_system_id  = aws_efs_file_system.this.id
  subnet_id       = module.vpc.private_subnets[tonumber(each.value)]
  security_groups = [module.sg_efs.id]
}

resource "aws_efs_access_point" "uidata" {
  file_system_id = aws_efs_file_system.this.id

  posix_user {
    uid = 10000
    gid = 10000
  }
  root_directory {
    path = "/ui"
    creation_info {
      owner_uid   = 10000
      owner_gid   = 10000
      permissions = "0755"
    }
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-efs-uidata" })
}

resource "aws_efs_access_point" "vectordata" {
  file_system_id = aws_efs_file_system.this.id

  posix_user {
    uid = 10001
    gid = 10001
  }
  root_directory {
    path = "/metrics"
    creation_info {
      owner_uid   = 10001
      owner_gid   = 10001
      permissions = "0755"
    }
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-efs-vectordata" })
}

resource "aws_efs_access_point" "sharedfiles" {
  file_system_id = aws_efs_file_system.this.id

  posix_user {
    uid = 10002
    gid = 10002
  }
  root_directory {
    path = "/server-shared"
    creation_info {
      owner_uid   = 10002
      owner_gid   = 10002
      permissions = "0755"
    }
  }

  tags = merge(local.tags, { Name = "${local.name_prefix}-efs-sharedfiles" })
}
