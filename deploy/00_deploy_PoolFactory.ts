import { HardhatRuntimeEnvironment } from 'hardhat/types'
import type { DeployFunction } from 'hardhat-deploy/types'

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts } = hre
  const { deploy } = deployments

  const { deployer } = await getNamedAccounts()

  // wMATIC
  const wMATIC = '0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270'

  await deploy('PoolFactory', {
    from: deployer,
    args: [wMATIC],
    log: true,
  })
}
export default func
