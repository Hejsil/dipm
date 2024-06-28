A package manager for installing linux programs that are self contained

# How to use

```sh
$ dipm install fzf # Install fzf

$ ls ~/.local/bin/fzf # fzf has now been installed in ~/.local/bin
/home/user/.local/bin/fzf

$ dipm uninstall fzf # Uninstall fzf
```

# How to install

```sh
curl -L https://github.com/hejsil/dipm/releases/download/0.9.0/dipm-x86_64-linux-musl > /tmp/dipm &&
    chmod +x /tmp/dipm &&
    /tmp/dipm install dipm &&
    rm /tmp/dipm
```

# Why?

I love Arch linux. The main reason for this is the Arch User Repositiory (AUR). With the AUR, most
tools a developer could ever want can be installed on the system with relative ease.

But life isn't always kind and sometimes you end up having to use Ubuntu. I'm sure the distro has
many advantages, but the package repositiory is a fraction of the size.

I want to use [zoxide](https://github.com/ajeetdsouza/zoxide),
[eza](https://github.com/eza-community/eza), [fzf](https://github.com/junegunn/fzf) and other modern
tools, but they either don't exist in the package repo or is very out of date.

Most of these tools end up creating distro independent binary releases so anyone can use them. They
then guide their users to download and run install scripts like so:

```sh
curl <my-cool-pkg-install-script> | sh
```

But imagine a world where we had a package manager for installing these binaries. This is what `dipm`
tries to be.
