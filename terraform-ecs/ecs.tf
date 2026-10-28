# Cluster + 4 services (server/ui/vectors/mcp) as entries in this module's single `services` map
# input. metrics is a separate module call at the end of this file, so it deploys first (see the
# comment on module "metrics").
#
# Launch type: Fargate everywhere, matching the original Copilot setup -- this keeps the module
# swap isolated from the compute model (awsvpc networking, Service Connect, and per-task EFS
# mounts all depend on it).

module "ecs" {
  source  = "terraform-aws-modules/ecs/aws"
  version = "7.5.0"

  # A target group only counts as "associated with a load balancer" once a listener uses it --
  # AWS rejects `aws_ecs_service.CreateService` on a target group with no listener yet, with
  # "does not have an associated load balancer". Nothing in the service definitions below
  # references the listeners directly (only the target group ARNs), so without this explicit
  # depends_on, Terraform has no graph edge forcing the listeners to exist first.
  #
  # Same reasoning for the other entries here:
  # - aws_efs_mount_target.this: server and ui reference the EFS file system and access
  #   points in their `volume` blocks, but never the mount targets themselves. Without this,
  #   ECS can schedule a task before the NFS mount target in that task's AZ is available, and
  #   the task fails with "Failed to resolve fs-....efs...amazonaws.com".
  # - aws_secretsmanager_secret_version.{mcp_token,ui_webui_secret_key}: task_exec_secret_arns
  #   below reference the *secret* resource's ARN, which exists before the *version* resource
  #   populates an actual value. A secret with zero versions has nothing for GetSecretValue to
  #   return.
  #
  # aws_s3_object.config_json and the public listener rules are not in this list. A change to an
  # entry here delays every data source in this module to the apply. The plan then replaces each
  # task definition and service security group. Instead, the two `init` containers reference the
  # etag of the object (CONFIG_JSON_ETAG below). The services read the public target groups
  # through the rules (local.*_public_target_group_arn in alb.tf). Both references put these
  # resources first, without the delay.
  depends_on = [
    aws_lb_listener.public_http,
    aws_lb_listener.internal_server_http,
    aws_lb_listener.internal_vectors_http,
    aws_efs_mount_target.this,
    aws_secretsmanager_secret_version.mcp_token,
    aws_secretsmanager_secret_version.ui_webui_secret_key,
  ]

  cluster_name = local.name_prefix

  cluster_setting = [
    {
      name  = "containerInsights"
      value = var.container_insights ? "enabled" : "disabled"
    }
  ]

  services = {
    server = {
      cpu                      = var.server_cpu
      memory                   = var.server_memory
      requires_compatibilities = ["FARGATE"]
      launch_type              = "FARGATE"

      subnet_ids         = module.vpc.private_subnets
      security_group_ids = [module.sg_tasks.id]
      assign_public_ip   = false

      # One task only. Each server task also runs the scheduler and rbac_mint, so a second task
      # runs both twice. The module default scales each service up to 10 tasks.
      enable_autoscaling = false

      # Deploy after metrics, and again when metrics can have new endpoints. See module "metrics".
      force_new_deployment = true
      triggers             = local.metrics_triggers

      # rbac_mint reads MCP_SERVER_TOKEN from Secrets Manager, so the execution role needs this.
      task_exec_secret_arns = [aws_secretsmanager_secret.mcp_token.arn]

      # server is behind two ALBs: the internal-server ALB (ui and mcp), and the public ALB
      # (/autoptic-api/, only with auth_enforce on). A target group belongs to one ALB only.
      load_balancer = merge(
        {
          server = {
            container_name   = "server"
            container_port   = 9999
            target_group_arn = aws_lb_target_group.server.arn
          }
        },
        local.public_api_enabled ? {
          server_public = {
            container_name   = "server"
            container_port   = 9999
            target_group_arn = local.server_public_target_group_arn
          }
        } : {},
      )

      volume = {
        sharedfiles = {
          efs_volume_configuration = {
            file_system_id = aws_efs_file_system.this.id
            authorization_config = {
              access_point_id = aws_efs_access_point.sharedfiles.id
              iam             = "ENABLED"
            }
            transit_encryption = "ENABLED"
          }
        }
      }

      container_definitions = {
        # Non-essential: pulls config.json from S3 onto the shared EFS volume before
        # server/scheduler are allowed to start. Overriding entrypoint is required --
        # this image's own ENTRYPOINT is already `aws`, not a shell.
        init = {
          image                  = "public.ecr.aws/aws-cli/aws-cli:latest"
          essential              = false
          readonlyRootFilesystem = false
          entrypoint             = ["/bin/sh", "-c"]
          # chmod 600: anyone who can read config.json can fetch every role token through bootstrap.
          # The EFS access point maps every client to one POSIX user, so only server, scheduler
          # and rbac_mint (same task, same access point) can still read it.
          command = ["aws s3 cp s3://${module.deploy_artifacts.s3_bucket_id}/config.json /mnt/shared/config.json && chmod 600 /mnt/shared/config.json"]
          # The command does not use this value. It makes the upload come before this task. A new
          # config.json gives a new task definition revision. Thus ECS restarts server and
          # scheduler with the new file. The ui task has the same variable.
          environment = [
            { name = "CONFIG_JSON_ETAG", value = aws_s3_object.config_json.etag },
          ]
          mountPoints = [{
            sourceVolume  = "sharedfiles"
            containerPath = "/mnt/shared"
            readOnly      = false
          }]
        }

        # Non-essential: runs "setup --run" first. It creates the DynamoDB tables and the S3
        # snapshot bucket when they are missing. It changes nothing that exists, so each task
        # start can run it. The api command does not create tables, and rbac_mint needs them.
        setup_run = {
          image                  = var.server_image
          essential              = false
          readonlyRootFilesystem = false
          command                = ["setup", "--run", "/mnt/shared/config.json"]
          # startTimeout is on the container that others wait for. The module default is 30s, but
          # on a first start this container creates 8 tables at about 10s each. After 30s, ECS
          # stops the task with "Task failed to start". 120s is the Fargate maximum. A retry skips
          # the tables that exist.
          startTimeout = 120
          mountPoints = [{
            sourceVolume  = "sharedfiles"
            containerPath = "/mnt/shared"
            readOnly      = true
          }]
          dependsOn = [{ containerName = "init", condition = "SUCCESS" }]
        }

        # Non-essential: runs "setup --rbac" before server and scheduler start, so the API never
        # runs with enforce on and no tokens. It mints the role and machine tokens. It never
        # replaces a value that exists, so a task restart is safe. It logs the ids only, not the
        # values. Get role.admin through bootstrap (README.md, "Access control").
        # MCP_SERVER_ID and MCP_SERVER_TOKEN are for a planned setup --rbac step that registers
        # mcp.autoptic.service.<mcp_server_id>. Released servers ignore both.
        rbac_mint = {
          image                  = var.server_image
          essential              = false
          readonlyRootFilesystem = false
          command                = ["setup", "--rbac", "/mnt/shared/config.json"]
          environment = [
            { name = "MCP_SERVER_ID", value = var.mcp_server_id },
          ]
          secrets = [
            { name = "MCP_SERVER_TOKEN", valueFrom = aws_secretsmanager_secret.mcp_token.arn },
          ]
          # server and scheduler wait for this container. See startTimeout on setup_run.
          startTimeout = 120
          mountPoints = [{
            sourceVolume  = "sharedfiles"
            containerPath = "/mnt/shared"
            readOnly      = true
          }]
          dependsOn = [{ containerName = "setup_run", condition = "SUCCESS" }]
        }

        server = {
          essential              = true
          readonlyRootFilesystem = false
          image                  = var.server_image
          command                = ["api", "-config", "/mnt/shared/config.json"]
          portMappings           = [{ containerPort = 9999, name = "server-9999", protocol = "tcp" }]
          # Access control is on by default. The load balancer is the proxy for every caller, so
          # the API trusts the VPC range for the client address in X-Forwarded-For.
          environment = [
            { name = "AUTH_ENFORCE", value = tostring(var.auth_enforce) },
            { name = "AUTH_OBSERVE", value = tostring(var.auth_observe) },
            { name = "AUTH_PERMISSIONS", value = tostring(var.auth_permissions) },
            { name = "AUTH_BOOTSTRAP_SHA_ENABLE", value = tostring(var.auth_bootstrap_sha_enable) },
            { name = "AUTH_TRUSTED_PROXIES", value = join(",", local.auth_trusted_proxies) },
          ]
          mountPoints = [{
            sourceVolume  = "sharedfiles"
            containerPath = "/mnt/shared"
            readOnly      = true
          }]
          dependsOn = [
            { containerName = "init", condition = "SUCCESS" },
            { containerName = "rbac_mint", condition = "SUCCESS" },
          ]
        }

        scheduler = {
          essential              = true
          readonlyRootFilesystem = false
          image                  = var.server_image
          command                = ["scheduler", "-config", "/mnt/shared/config.json"]
          mountPoints = [{
            sourceVolume  = "sharedfiles"
            containerPath = "/mnt/shared"
            readOnly      = true
          }]
          # The scheduler fetches its own token through bootstrap, so it needs no AUTH_* env.
          dependsOn = [
            { containerName = "init", condition = "SUCCESS" },
            { containerName = "rbac_mint", condition = "SUCCESS" },
          ]
        }
      }

      # Client-only Service Connect membership -- no `service` entry, since nothing calls
      # server via Service Connect (it's reached through the internal-server ALB instead).
      # This join is what lets server resolve the bare "metrics" hostname for its own direct
      # Qdrant gRPC client (config.json's vector.qdrant_host, set to "metrics" below). Without
      # this block, server has no path to metrics at all.
      service_connect_configuration = {
        enabled   = true
        namespace = aws_service_discovery_private_dns_namespace.this.arn
      }

      # Direct port of addons/server-policy.yml -- Create* permissions are intentional: the
      # setup_run container creates the DynamoDB tables and S3 snapshot bucket on first start.
      # The server names them autoptic-<table>-<instance id> and autoptic-snaps-<instance id>,
      # and the instance id starts with the tenant short name.
      tasks_iam_role_statements = [
        {
          sid    = "SelfProvisionedDynamoDB"
          effect = "Allow"
          actions = [
            "dynamodb:CreateTable",
            "dynamodb:DescribeTable",
            "dynamodb:DescribeTimeToLive",
            "dynamodb:UpdateTimeToLive",
            # setup --run adds a missing index (GSI) to a table that exists.
            "dynamodb:UpdateTable",
            "dynamodb:PutItem",
            "dynamodb:GetItem",
            "dynamodb:Query",
            "dynamodb:DeleteItem",
            "dynamodb:ListTables",
          ]
          resources = ["arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/autoptic-*-${var.tenant_short_name}-*"]
        },
        {
          sid    = "SelfProvisionedS3Snapshots"
          effect = "Allow"
          actions = [
            "s3:CreateBucket",
            "s3:PutObject",
            "s3:GetObject",
            "s3:ListBucket",
            "s3:DeleteObject",
          ]
          resources = [
            "arn:aws:s3:::autoptic-snaps-${var.tenant_short_name}-*",
            "arn:aws:s3:::autoptic-snaps-${var.tenant_short_name}-*/*",
          ]
        },
        {
          sid       = "ReadConfigJson"
          effect    = "Allow"
          actions   = ["s3:GetObject"]
          resources = ["${module.deploy_artifacts.s3_bucket_arn}/config.json"]
        },
        {
          sid       = "SharedFilesEfsAccess"
          effect    = "Allow"
          actions   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
          resources = [aws_efs_file_system.this.arn]
          condition = [{
            test     = "StringEquals"
            variable = "elasticfilesystem:AccessPointArn"
            values   = [aws_efs_access_point.sharedfiles.arn]
          }]
        },
      ]
    }

    ui = {
      cpu                      = var.ui_cpu
      memory                   = var.ui_memory
      requires_compatibilities = ["FARGATE"]
      launch_type              = "FARGATE"

      subnet_ids         = module.vpc.private_subnets
      security_group_ids = [module.sg_tasks.id]
      assign_public_ip   = false

      # One task only. The web app keeps its data on EFS (uidata), and a second task shares it.
      enable_autoscaling = false

      # See the comment on mcp's task_exec_secret_arns below -- same reasoning applies here.
      task_exec_secret_arns = [aws_secretsmanager_secret.ui_webui_secret_key.arn]

      load_balancer = {
        ui = {
          container_name   = "ui"
          container_port   = 8080
          target_group_arn = aws_lb_target_group.ui.arn
        }
      }

      volume = {
        uidata = {
          efs_volume_configuration = {
            file_system_id = aws_efs_file_system.this.id
            authorization_config = {
              access_point_id = aws_efs_access_point.uidata.id
              iam             = "ENABLED"
            }
            transit_encryption = "ENABLED"
          }
        }
      }

      container_definitions = {
        # Non-essential: pulls config.json from S3 onto the ui data volume. The web app sends the
        # SHA-256 of this file to the bootstrap route to fetch its role tokens. Thus the bytes must
        # be the same as the file of server and scheduler. chmod 600, as for the server task.
        init = {
          image                  = "public.ecr.aws/aws-cli/aws-cli:latest"
          essential              = false
          readonlyRootFilesystem = false
          entrypoint             = ["/bin/sh", "-c"]
          command                = ["aws s3 cp s3://${module.deploy_artifacts.s3_bucket_id}/config.json /app/backend/data/config.json && chmod 600 /app/backend/data/config.json"]
          # See CONFIG_JSON_ETAG in the server task. A new config.json restarts ui too, so the web
          # app and the API keep the same file for bootstrap.
          environment = [
            { name = "CONFIG_JSON_ETAG", value = aws_s3_object.config_json.etag },
          ]
          mountPoints = [{
            sourceVolume  = "uidata"
            containerPath = "/app/backend/data"
            readOnly      = false
          }]
        }

        ui = {
          essential              = true
          readonlyRootFilesystem = false
          image                  = var.ui_image
          portMappings           = [{ containerPort = 8080, name = "ui-8080", protocol = "tcp" }]
          dependsOn              = [{ containerName = "init", condition = "SUCCESS" }]
          mountPoints = [{
            sourceVolume  = "uidata"
            containerPath = "/app/backend/data"
            readOnly      = false
          }]
          # Internal-server ALB DNS replaces the Cloud Map hostname this env var used under
          # Copilot -- ui no longer reaches server via Service Connect.
          # AUTOPTIC_ROLE_MAPPING is set only when ui_role_mapping is set. Without it, the web
          # app uses its own default (admin=role.admin, user=role.viewer).
          environment = concat(
            [
              { name = "AUTOPTIC_SERVER_URL", value = "http://${aws_lb.internal_server.dns_name}:9999/" },
              { name = "AUTOPTIC_CONFIG_PATH", value = "/app/backend/data/config.json" },
            ],
            var.ui_role_mapping != "" ? [{ name = "AUTOPTIC_ROLE_MAPPING", value = var.ui_role_mapping }] : [],
          )
          # open_webui/env.py raises at import time when WEBUI_AUTH (default true) is set and
          # WEBUI_SECRET_KEY == "". The image's start.sh can auto-generate one into a file next
          # to the app if the env var is absent, but that path isn't reliable here -- setting it
          # directly sidesteps the file-based fallback entirely.
          secrets = [
            { name = "WEBUI_SECRET_KEY", valueFrom = aws_secretsmanager_secret.ui_webui_secret_key.arn },
          ]
        }
      }

      tasks_iam_role_statements = [
        {
          sid       = "UiDataEfsAccess"
          effect    = "Allow"
          actions   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
          resources = [aws_efs_file_system.this.arn]
          condition = [{
            test     = "StringEquals"
            variable = "elasticfilesystem:AccessPointArn"
            values   = [aws_efs_access_point.uidata.arn]
          }]
        },
        {
          sid       = "ReadConfigJson"
          effect    = "Allow"
          actions   = ["s3:GetObject"]
          resources = ["${module.deploy_artifacts.s3_bucket_arn}/config.json"]
        },
      ]
    }

    vectors = {
      # Sized for an ~1.3GB e5-large-v2 model by default -- undersizing causes an mmap
      # allocation failure at startup, not just slow inference.
      cpu                      = var.vectors_cpu
      memory                   = var.vectors_memory
      requires_compatibilities = ["FARGATE"]
      launch_type              = "FARGATE"

      subnet_ids         = module.vpc.private_subnets
      security_group_ids = [module.sg_tasks.id]
      assign_public_ip   = false

      # Deploy after metrics, and again when metrics can have new endpoints. See module "metrics".
      force_new_deployment = true
      triggers             = local.metrics_triggers

      load_balancer = {
        vectors = {
          container_name   = "vectors"
          container_port   = 8000
          target_group_arn = aws_lb_target_group.vectors.arn
        }
      }

      container_definitions = {
        vectors = {
          essential = true
          # This is the fix for the vectors crash: torch's import chain calls
          # tempfile.TemporaryDirectory() as a side effect, and vectors has no EFS mount to fall
          # back on (unlike server/ui/metrics), so a read-only root filesystem leaves it with
          # nowhere writable at all. No tmpfs/emptyDir volume is added alongside it -- the
          # module's readonlyRootFilesystem default of true was never an intentional choice
          # here, just an unexamined module default.
          readonlyRootFilesystem = false
          image                  = var.vectors_image
          portMappings           = [{ containerPort = 8000, name = "vectors-8000", protocol = "tcp" }]
          # server.py defaults QDRANT_URL to http://localhost:6333, which doesn't exist here --
          # /health (and every search/embed call) needs Qdrant's REST port on metrics, reached
          # via Service Connect, not the gRPC port 6334 that server's config.json uses.
          #
          # Bare short name, not an FQDN: ECS Service Connect doesn't publish a real DNS record
          # at all -- it statically injects the alias into /etc/hosts as just "metrics" (mapped
          # to a reserved 127.255.x.x loopback address that the Envoy sidecar intercepts via
          # iptables). "metrics.<ENV_NAME>.<APP_NAME>.local" does not resolve inside the task.
          environment = [
            { name = "QDRANT_URL", value = "http://metrics:6333" },
          ]
        }
      }

      # So vectors can resolve metrics.<env>.<app>.local:6334 -- the one hop still on
      # Service Connect instead of an ALB.
      service_connect_configuration = {
        enabled   = true
        namespace = aws_service_discovery_private_dns_namespace.this.arn
        service = [{
          port_name      = "vectors-8000"
          discovery_name = "vectors"
          client_alias = {
            port     = 8000
            dns_name = "vectors"
          }
        }]
      }
    }

    mcp = {
      cpu                      = var.mcp_cpu
      memory                   = var.mcp_memory
      requires_compatibilities = ["FARGATE"]
      launch_type              = "FARGATE"

      subnet_ids         = module.vpc.private_subnets
      security_group_ids = [module.sg_tasks.id]
      assign_public_ip   = false

      # ECS resolves the `secrets` block below using the EXECUTION role, not the task role --
      # the execution role acts before the task role is ever assumed. task_exec_secret_arns is
      # the module's built-in mechanism for this (it grants secretsmanager:GetSecretValue on
      # exactly these ARNs); a statement under tasks_iam_role_statements would grant the wrong
      # role and every task would fail with AccessDeniedException at startup.
      task_exec_secret_arns = [aws_secretsmanager_secret.mcp_token.arn]

      # MCP clients reach mcp through /mcp on the public ALB. mcp has no internal ALB.
      load_balancer = {
        mcp = {
          container_name   = "mcp"
          container_port   = 7000
          target_group_arn = local.mcp_public_target_group_arn
        }
      }

      container_definitions = {
        mcp = {
          essential              = true
          readonlyRootFilesystem = false
          image                  = var.mcp_image
          portMappings           = [{ containerPort = 7000, name = "mcp-7000", protocol = "tcp" }]
          environment = [
            { name = "SERVER_PORT", value = "7000" },
            { name = "AUTOPTIC_API_BASE_URL", value = "http://${aws_lb.internal_server.dns_name}:9999/" },
            { name = "MCP_ADMIN_TOOLS_ENABLED", value = tostring(var.mcp_admin_tools_enabled) },
            { name = "MCP_SERVER_ID", value = var.mcp_server_id },
          ]
          secrets = [
            { name = "MCP_SERVER_TOKEN", valueFrom = aws_secretsmanager_secret.mcp_token.arn },
          ]
          # No container-level healthCheck here -- aws_lb_target_group.mcp_public (alb.tf) already
          # runs an HTTP health check against /health on this same port.
        }
      }
    }
  }

  tags = local.tags
}

# metrics is its own module call, so its Service Connect endpoint exists before vectors and server
# deploy. Service Connect gives a task only the endpoints that existed when the current deployment
# of its service started. A replacement task keeps that list. As an entry in the services map of
# module "ecs", metrics deploys together with the others. Then vectors can miss "metrics", and its
# /health answers 503 until its next deployment. vectors and server use local.metrics_triggers.
locals {
  # A change here changes the endpoints of metrics, so it is part of local.metrics_triggers.
  metrics_service_connect = {
    enabled   = true
    namespace = aws_service_discovery_private_dns_namespace.this.arn
    service = [
      {
        # discovery_name stays "metrics" (unchanged from before this fix) -- AWS won't let
        # a client_alias move to a new discovery_name while the old one is still live on
        # the running service, so renaming this alongside adding the new REST entry below
        # deadlocks UpdateService with "ClientAlias ... already used by service with
        # discovery name metrics".
        port_name      = "metrics-6334"
        discovery_name = "metrics"
        client_alias = {
          port     = 6334
          dns_name = "metrics"
        }
      },
      {
        port_name      = "metrics-6333"
        discovery_name = "metrics-rest"
        client_alias = {
          port     = 6333
          dns_name = "metrics"
        }
      },
    ]
  }

  # vectors and server deploy after metrics, because they reference module.metrics.id. They
  # deploy again when metrics is replaced or its Service Connect configuration changes.
  metrics_triggers = {
    metrics_service         = module.metrics.id
    metrics_service_connect = sha1(jsonencode(local.metrics_service_connect))
  }
}

module "metrics" {
  source  = "terraform-aws-modules/ecs/aws//modules/service"
  version = "7.5.0"

  # The vectordata volume needs the EFS mount targets. See depends_on in module "ecs".
  depends_on = [aws_efs_mount_target.this]

  name        = "metrics"
  cluster_arn = module.ecs.cluster_arn

  cpu                      = var.metrics_cpu
  memory                   = var.metrics_memory
  requires_compatibilities = ["FARGATE"]
  launch_type              = "FARGATE"

  subnet_ids         = module.vpc.private_subnets
  security_group_ids = [module.sg_tasks.id]
  assign_public_ip   = false

  # One task only. Qdrant keeps its data on EFS (vectordata). Two Qdrant processes on the same
  # storage can corrupt it.
  enable_autoscaling = false

  # No load_balancer block. vectors and server reach metrics over Service Connect, with no ALB
  # in between.

  volume = {
    vectordata = {
      efs_volume_configuration = {
        file_system_id = aws_efs_file_system.this.id
        authorization_config = {
          access_point_id = aws_efs_access_point.vectordata.id
          iam             = "ENABLED"
        }
        transit_encryption = "ENABLED"
      }
    }
  }

  container_definitions = {
    metrics = {
      essential              = true
      readonlyRootFilesystem = false
      image                  = var.metrics_image
      # 6334 = Qdrant's gRPC port, for the Qdrant client of server (config.json
      # vector.qdrant_host "metrics", qdrant_port 6334). server reaches it through its
      # client-only Service Connect membership.
      # 6333 = Qdrant's REST port (vectors' /health check and its QdrantClient(url=...)).
      # Both are registered under the same "metrics" Service Connect dns_name below.
      portMappings = [
        { containerPort = 6334, name = "metrics-6334", protocol = "tcp" },
        { containerPort = 6333, name = "metrics-6333", protocol = "tcp" },
      ]
      mountPoints = [{
        sourceVolume  = "vectordata"
        containerPath = "/qdrant/storage"
        readOnly      = false
      }]
    }
  }

  service_connect_configuration = local.metrics_service_connect

  tasks_iam_role_statements = [
    {
      sid       = "VectorDataEfsAccess"
      effect    = "Allow"
      actions   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
      resources = [aws_efs_file_system.this.arn]
      condition = [{
        test     = "StringEquals"
        variable = "elasticfilesystem:AccessPointArn"
        values   = [aws_efs_access_point.vectordata.arn]
      }]
    },
  ]

  tags = local.tags
}

# Older installs have metrics inside module "ecs". This block moves its state, so an upgrade keeps
# the running service and changes nothing on it.
moved {
  from = module.ecs.module.service["metrics"]
  to   = module.metrics
}
