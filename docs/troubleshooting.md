# Troubleshooting

## `nx check` Fails Because Role Is Wrong

Check:

```bash
cat /etc/nixos/.nixos-role
```

It must be:

```text
laptop
```

or:

```text
server
```

Override for one command:

```bash
nx check --role laptop
```

## `nx generate` Cannot See Generated Or Local Files

Use `nx generate` or `generate.sh`. They use a `path:` flake ref:

```text
path:/etc/nixos#install-<role>-generated
```

Do not replace that with a plain git flake ref if you need ignored files such as `generated/` and `specific/`.

## Cannot Edit `/etc/nixos`

Check group membership:

```bash
id
```

The user should be in `corner`.

Check ownership:

```bash
ls -ld /etc/nixos
```

Expected:

```text
root corner
```

If the user was just added to `corner`, log out and log back in.

## Git Says `/etc/nixos` Has Dubious Ownership

Git prints this when the repo is owned by `root:corner` and the current user is not the owner. This repo config marks `/etc/nixos` safe at the system level:

```gitconfig
[safe]
  directory = /etc/nixos
```

After applying the latest system config, `/etc/gitconfig` should contain that entry. Temporary per-user workaround:

```bash
git config --global --add safe.directory /etc/nixos
```

## `nx secret` Says `pcscd` Is Not Running

Start pcscd:

```bash
sudo systemctl start pcscd.service
```

Then retry:

```bash
nx secret secrets/system.yaml
```

## Disko Root Mountpoint Error

A valid generated Disko root subvolume should look like:

```nix
subvolumes = {
  "/@root" = {
    mountpoint = "/";
  };
};
```

Regenerate the Disko file with the wizard if the generated file is malformed.

## Full Repo Check

Run:

```bash
./scripts/check.sh
```

This checks shell syntax, Nix parse, laptop/server config eval, and whitespace.
