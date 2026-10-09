%global debug_package %{nil}

Name:           szn
Version:        0.10.0
Release:        1%{?dist}
Summary:        Modern terminal multiplexer rewritten in Zig

License:        MIT
URL:            https://github.com/cwt/szn
Source0:        %{url}/archive/refs/tags/v%{version}.tar.gz#/%{name}-%{version}.tar.gz

ExclusiveArch:  %{zig_arches}

BuildRequires:  zig >= 0.16.0
BuildRequires:  zig-rpm-macros

Recommends:     libthai

# Compile in ReleaseFast mode for optimal multiplexer throughput
%global _zig_release_mode fast

# Target CPU microarchitecture level per distro and arch:
# - On x86_64: EL10 uses x86_64_v3; Fedora and EL9 use x86_64_v2
# - On other architectures (aarch64, riscv64, etc.): use baseline
%ifarch x86_64
%if 0%{?rhel} >= 10
%global _zig_cpu x86_64_v3
%else
%global _zig_cpu x86_64_v2
%endif
%else
%global _zig_cpu baseline
%endif

%description
szn is a modern terminal multiplexer inspired by tmux, rewritten from scratch
in Zig. It assumes a modern terminal baseline (xterm-256color or newer),
providing UTF-8 box-drawing, SGR mouse tracking, kitty extended keys,
and true-color support out of the box with zero legacy terminal overhead.

%prep
%autosetup -p1
%zig_prep

%build
%zig_build -Dpie=true

%install
%zig_install

%check
# Isolate runtime directory so unit tests do not collide with running sessions
XDG_RUNTIME_DIR=$(mktemp -d) %zig_test

%files
%license LICENSE
%doc README.md
%{_bindir}/szn

%changelog
* Fri Oct 09 2026 Szn Maintainers <cwt@users.noreply.github.com> - 0.10.0-1
- Initial RPM package release for Fedora and Enterprise Linux
