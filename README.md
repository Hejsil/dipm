A package manager for installing linux programs that are self contained.

![readme.gif](./readme.gif)

Packages are defined in [`dipm-pkgs`](https://github.com/Hejsil/dipm-pkgs).

# How to install

```sh
curl -L "https://github.com/Hejsil/dipm/releases/latest/download/dipm-$(uname -m)-$(uname -s)-musl" > /tmp/dipm &&
    chmod +x /tmp/dipm &&
    /tmp/dipm install dipm &&
    rm /tmp/dipm
```

# Why?

I love Arch linux. The main reason for this is the Arch User Repository (AUR). With the AUR, most
tools a developer could ever want can be installed on the system with relative ease.

But life isn't always kind and sometimes you end up having to use Ubuntu. I'm sure the distro has
many advantages, but the package repository is a fraction of the size.

I want to use [zoxide](https://github.com/ajeetdsouza/zoxide),
[eza](https://github.com/eza-community/eza), [fzf](https://github.com/junegunn/fzf) and other modern
tools, but they either don't exist in the package repo or is very out of date.

Most of these tools end up creating distro independent binary releases so anyone can use them. They
then guide their users to download and run install scripts like so:

```sh
curl <my-cool-pkg-install-script> | sh
```

But imagine a world where we had a package manager for installing these binaries. This is what
`dipm` tries to be.

# Why not X?

There are package managers that work on multiple distros like [homebrew](https://brew.sh/) or
[nix](https://nixos.org/). While these are great, they're quite complicated for what I want.

There are also [eget](https://github.com/zyedidia/eget) and
[stow](https://github.com/marwanhawari/stew) which are much simpler. The only issue I see with these
is that they are dependent on Github and cannot install binaries from elsewhere.
