# Cluster + all 5 services (server/ui/metrics/vectors/mcp) as entries in this module's single
# `services` map input. No separate bespoke task-def resource for `server` and no separate child
# module for the other 4 -- they're all just entries in the same map.
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
  # Same reasoning for the other 3 entries here, each closing a real race a code review caught:
  # - aws_efs_mount_target.this: server/ui/metrics reference the EFS file system and access
  #   points in their `volume` blocks, but never the mount targets themselves. Without this,
  #   ECS can schedule a task before the NFS mount target in that task's AZ is available --
  #   this is the exact transient "Failed to resolve fs-....efs...amazonaws.com" error seen on
  #   this project's first real apply.
  # - aws_s3_object.config_json: server's `init` sidecar command interpolates
  #   module.deploy_artifacts.s3_bucket_id (the bucket), never the object upload itself, so
  #   nothing orders the upload before the ECS service exists -- the sidecar's `aws s3 cp` can
  #   race the upload and fail with a missing-key error on a first apply.
  # - aws_secretsmanager_secret_version.{mcp_token,ui_webui_secret_key}: task_exec_secret_arns
  #   below reference the *secret* resource's ARN, which exists before the *version* resource
  #   populates an actual value. A secret with zero versions has nothing for GetSecretValue to
  #   return.
  depends_on = [
    aws_lb_listener.public_http,
    aws_lb_listener.internal_server_http,
    aws_lb_listener.internal_vectors_http,
    aws_lb_listener.internal_mcp_http,
    aws_efs_mount_target.this,
    aws_s3_object.config_json,
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

      load_balancer = {
        server = {
          container_name   = "server"
          container_port   = 9999
          target_group_arn = aws_lb_target_group.server.arn
        }
      }

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
          command                = ["aws s3 cp s3://${module.deploy_artifacts.s3_bucket_id}/config.json /mnt/shared/config.json"]
          mountPoints = [{
            sourceVolume  = "sharedfiles"
            containerPath = "/mnt/shared"
            readOnly      = false
          }]
        }

        server = {
          essential              = true
          readonlyRootFilesystem = false
          image                  = var.server_image
          command                = ["api", "-config", "/mnt/shared/config.json"]
          portMappings           = [{ containerPort = 9999, name = "server-9999", protocol = "tcp" }]
          mountPoints = [{
            sourceVolume  = "sharedfiles"
            containerPath = "/mnt/shared"
            readOnly      = true
          }]
          dependsOn = [{ containerName = "init", condition = "SUCCESS" }]
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
          dependsOn = [{ containerName = "init", condition = "SUCCESS" }]
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

      # Direct port of addons/server-policy.yml -- Create* permissions are intentional, the
      # app self-provisions its own DynamoDB tables and S3 snapshot bucket on first run.
      tasks_iam_role_statements = [
        {
          sid    = "SelfProvisionedDynamoDB"
          effect = "Allow"
          actions = [
            "dynamodb:CreateTable",
            "dynamodb:DescribeTable",
            "dynamodb:PutItem",
            "dynamodb:GetItem",
            "dynamodb:Query",
            "dynamodb:DeleteItem",
            "dynamodb:ListTables",
          ]
          resources = ["arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/${var.tenant_short_name}-*"]
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
            "arn:aws:s3:::${var.tenant_short_name}-snaps-*",
            "arn:aws:s3:::${var.tenant_short_name}-snaps-*/*",
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
        ui = {
          essential              = true
          readonlyRootFilesystem = false
          image                  = var.ui_image
          portMappings           = [{ containerPort = 8080, name = "ui-8080", protocol = "tcp" }]
          mountPoints = [{
            sourceVolume  = "uidata"
            containerPath = "/app/backend/data"
            readOnly      = false
          }]
          # Internal-server ALB DNS replaces the Cloud Map hostname this env var used under
          # Copilot -- ui no longer reaches server via Service Connect.
          environment = [
            { name = "AUTOPTIC_SERVER_URL", value = "http://${aws_lb.internal_server.dns_name}:9999/" },
          ]
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
      ]
    }

    metrics = {
      cpu                      = var.metrics_cpu
      memory                   = var.metrics_memory
      requires_compatibilities = ["FARGATE"]
      launch_type              = "FARGATE"

      subnet_ids         = module.vpc.private_subnets
      security_group_ids = [module.sg_tasks.id]
      assign_public_ip   = false

      # No load_balancer block -- vectors is the only caller of metrics (confirmed), so this
      # stays a direct Service Connect call with no ALB in between.

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
          # 6334 = Qdrant's gRPC port. config.json's vector.qdrant_port still points here
          # (Copilot's original value), but server has no service_connect_configuration in this
          # design -- it cannot resolve the bare "metrics" hostname Service Connect requires, so
          # this port is not actually reachable from server as configured. Left as-is only
          # because vectors is confirmed the sole real caller of metrics; if server's config.json
          # value turns out to matter, that's a design gap to fix, not a value to guess at here.
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

      service_connect_configuration = {
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
          # nowhere writable at all. The Helm chart sets this the same way for every service
          # (see values.yaml's containerSecurityContext.readOnlyRootFilesystem), with no
          # tmpfs/emptyDir volume alongside it -- the module's readonlyRootFilesystem default of
          # true was never an intentional choice on our side, just an unexamined module default.
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
          # iptables). "metrics.<ENV_NAME>.<APP_NAME>.local" is not resolvable inside the task;
          # confirmed by ECS Exec (`getent hosts` returns nothing for the FQDN, and
          # `cat /etc/hosts` shows only the bare name).
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

      load_balancer = {
        mcp = {
          container_name   = "mcp"
          container_port   = 7000
          target_group_arn = aws_lb_target_group.mcp.arn
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
          # No container-level healthCheck here -- aws_lb_target_group.mcp (alb.tf) already
          # runs an HTTP health check against /health on this same port.
        }
      }
    }
  }

  tags = local.tags
}
