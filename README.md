# Eth Docker: Docker automation for Ethereum nodes.

[![GitPOAP Badge](https://public-api.gitpoap.io/v1/repo/eth-educators/eth-docker/badge)](https://www.gitpoap.io/gh/eth-educators/eth-docker)

Eth Docker, a simple yet configurable way to run [Ethereum](https://ethereum.org/roadmap/) nodes.

## Getting Started

Please see the [official documentation](https://ethdocker.com).

For a quick testnet start, you can install prerequisites and configure Eth Docker, as any user not named `root`:

* `cd ~ && git clone https://github.com/ethstaker/eth-docker.git && cd eth-docker`
* `./ethd install`
* `./ethd config`

## Support

The #software channel in [ethstaker Discord](https://discord.gg/ethstaker) is the place to ask questions about Eth Docker.

## Contributions

Contributions are highly appreciated. We have [GitPOAPs](https://www.gitpoap.io/gh/eth-educators/eth-docker)! To make your life easier,
please read the [contribution guidelines](CONTRIBUTING.md) so you can run lint checks locally on pre-commit.

## License

[Apache License v2](LICENSE)

## Version

Eth Docker uses a "semver-ish" scheme.
- First digit, major shifts in how things work. The last one was the Ethereum merge. I do not expect another shift that
large.
- Second through fourth digit, [semver](https://semver.org/).

This is Eth Docker v2.17.0.0
