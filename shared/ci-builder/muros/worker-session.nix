{ pkgs, cores ? 1, maxJobs ? 1, jobs ? false, jobMemoryMax ? "8G", jobTasksMax ? 4096, jobCpusMax ? 256, jobTimeoutMax ? 86400, jobFeatures ? [ ] }:
assert cores >= 1 && cores <= 1024;
assert maxJobs >= 1 && maxJobs <= 1024;
assert jobCpusMax >= 1 && jobCpusMax <= 256;
assert jobTimeoutMax >= 1 && jobTimeoutMax <= 86400;
let
  profile = {
    protocol = "muros-worker-v3";
    policy = "local-only";
    package_system = pkgs.stdenv.hostPlatform.system;
    nix_version = pkgs.nix.version;
    inherit cores;
    max_jobs = maxJobs;
  } // pkgs.lib.optionalAttrs jobs {
    jobs = {
      memory_max = jobMemoryMax;
      tasks_max = jobTasksMax;
      cpus_max = jobCpusMax;
      timeout_max = jobTimeoutMax;
      features = jobFeatures;
    };
  };
  report = profile // {
    profile_id = builtins.hashString "sha256" (builtins.toJSON profile);
  };
  inspection = import ./worker-inspection.nix { inherit pkgs; profile = report; };
in pkgs.writeShellApplication {
  name = "muros-worker-session";
  runtimeInputs = [ pkgs.nix ];
  text = ''
    unset NIX_REMOTE NIX_CONFIG NIX_CONF_DIR
    export NIX_USER_CONF_FILES=/dev/null
    case "''${SSH_ORIGINAL_COMMAND:-}" in
      muros-worker-info-v1)
        printf '%s\n' ${pkgs.lib.escapeShellArg (builtins.toJSON report)}
        exit 0
        ;;
      muros-worker-inspect-v1)
        exec ${inspection}/bin/muros-worker-inspection
        ;;
      'nix-daemon --stdio'|'muros-worker-v2-build-${report.profile_id} --stdio')
        cores=${toString cores}
        jobs=${toString maxJobs}
        ;;
      'muros-worker-v2-probe-${report.profile_id} --stdio')
        cores=1
        jobs=1
        ;;
      'muros-worker-v3-job-${report.profile_id} '*' --stdio')
        ${if jobs then ''
        read -r _ step timeout own fallback flags _ <<< "$SSH_ORIGINAL_COMMAND"
        reject() {
          printf '%s\n' 'Invalid Muros job request.' >&2
          exit 126
        }
        if [[ ! "$step" =~ ^/nix/store/[0-9a-z]{32}-[^/]+/bin/muros-step$ ]] || [[ ! -x "$step" ]] || [[ ! "$timeout" =~ ^[0-9]{1,6}$ ]] \
          || (( timeout > ${toString jobTimeoutMax} )) || [[ ! "$own" =~ ^(-|[0-9a-f]{32})$ ]] || [[ ! "$fallback" =~ ^(-|[0-9a-f]{32})$ ]] || [[ ! "$flags" =~ ^(-|[a-zA-Z0-9=,]{1,128})$ ]]; then
          reject
        fi
        bytes() {
          local value=''${1%[KMG]}
          case "$1" in
            *K) echo $((value * 1024)) ;;
            *M) echo $((value * 1048576)) ;;
            *G) echo $((value * 1073741824)) ;;
            *) echo "$value" ;;
          esac
        }
        limits=()
        mode=(--stdio --workspace /var/tmp/muros-workspace)
        if [[ "$flags" != - ]]; then
          IFS=, read -ra items <<< "$flags"
          for item in "''${items[@]}"; do
            case "$item" in
              nonet) limits+=(--property=PrivateNetwork=yes) ;;
              probe) mode=(--probe) ;;
              kvm) ${if builtins.elem "kvm" jobFeatures then ''limits+=(--property=PrivateDevices=no "--property=DeviceAllow=/dev/kvm rw")'' else "reject"} ;;
              userns) ${if builtins.elem "userns" jobFeatures then ''limits+=(--property=RestrictNamespaces=no)'' else "reject"} ;;
              memory=*)
                value=''${item#memory=}
                if [[ ! "$value" =~ ^[0-9]{1,6}[KMG]$ ]] || (( $(bytes "$value") > $(bytes ${jobMemoryMax}) )); then
                  reject
                fi
                limits+=("--property=MemoryMax=$value")
                ;;
              cpus=*)
                value=''${item#cpus=}
                if [[ ! "$value" =~ ^[0-9]{1,3}$ ]] || (( value < 1 || value > ${toString jobCpusMax} )); then
                  reject
                fi
                limits+=("--property=CPUQuota=$((value * 100))%")
                ;;
              *) reject ;;
            esac
          done
        fi
        session=$(${pkgs.coreutils}/bin/basename "$(${pkgs.coreutils}/bin/cut -d: -f3 /proc/self/cgroup)")
        if [[ "$session" =~ ^(session-[0-9a-z]+\.scope|sshd@[0-9a-zA-Z:.-]+\.service)$ ]]; then
          limits+=("--property=BindsTo=$session" "--property=After=$session")
        fi
        cache=()
        if [[ "$own" != - ]]; then
          cache+=("--property=CacheDirectory=muros/$own")
        fi
        if [[ "$fallback" != - && "$fallback" != "$own" ]]; then
          cache+=("--property=BindReadOnlyPaths=-/var/cache/private/muros/$fallback:/var/cache/muros-default")
        fi
        exec ${pkgs.systemd}/bin/systemd-run --quiet --pipe --wait --collect --service-type=exec \
          --unit "muros-job-$(cat /proc/sys/kernel/random/uuid)" \
          --property=DynamicUser=yes --property=PrivateTmp=yes --property=ProtectSystem=strict \
          --property=ProtectHome=yes --property=NoNewPrivileges=yes --property=PrivateDevices=yes --property=RestrictNamespaces=yes \
          --property=RuntimeMaxSec="$timeout" --property=MemoryMax=${jobMemoryMax} \
          --property=TasksMax=${toString jobTasksMax} --property=WorkingDirectory=/var/tmp "''${cache[@]}" "''${limits[@]}" \
          -- "$step" "''${mode[@]}"
        '' else ''
        printf '%s\n' 'This Muros worker does not run jobs; enable services.muros-worker.jobs.enable.' >&2
        exit 126
        ''}
        ;;
      *)
        printf '%s\n' 'Muros worker profile mismatch or unsupported operation; review and probe this worker again.' >&2
        exit 126
        ;;
    esac
    exec ${pkgs.nix}/bin/nix-daemon \
      --extra-experimental-features 'nix-command flakes mounted-ssh-store' --stdio --process-ops --store daemon \
      --option builders "" --option cores "$cores" --option max-jobs "$jobs" \
      --option sandbox true --option accept-flake-config false
  '';
}
