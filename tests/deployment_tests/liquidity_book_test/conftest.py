import pytest
from brownie import (
    ZERO_ADDRESS, BaseRewardPool, CompounderJoe, CompounderPTP, LBPool, Oracle, OracleHelper, PoolHelperJoeV2,
    ReceiptsHolder, SimplePoolHelper, Strategy, ViewHelper, Wei, accounts, chain, interface
)
from brownie.exceptions import VirtualMachineError
from py_vector.common.testing import simple_isolation
from py_vector.common.upgrades import deploy_upgradeable_contract
from py_vector.common.upgrades.storage import write_balance
from py_vector.vector.mainnet import DeploymentMap, get_deployment
from py_vector.vector.mainnet.deployed_contracts import no_connect_deployment
from py_vector.vector.mainnet.deployment_map import JoeLBPool, JoeLBPools
from py_vector.vector.upgrades import mass_upgrade_to_current_state


@pytest.fixture(scope='package', params=JoeLBPools.__fields__)
def pool_name(request, deployment: DeploymentMap):
    return request.param


@pytest.fixture(scope='package')
def pool_contracts(deployment: DeploymentMap, pool_name):
    return getattr(deployment.JOE.LB.pools, pool_name)


def setup_pool(
    deployment: DeploymentMap, pool: JoeLBPool, strategy_owner
):
    deploy_parameters = deployment.ACCOUNTS.deployer.parameters()
    proxy_admin = deployment.PTP.proxy_admin
    router = deployment.JOE.LB.ROUTER
    token1, token2 = deployment.get_tokens_for_joe_lb(pool)
    bin_step = pool.bin_step
    view_helper, _ = deploy_upgradeable_contract(
        deploy_parameters,
        ViewHelper,
        "__ViewHelper_init",
        proxy_admin
    )
    vault, _ = deploy_upgradeable_contract(
        deploy_parameters,
        LBPool,
        "__LBPool_init",
        proxy_admin,
        token1,
        token2,
        bin_step,
        router,
        pool.receipt_token,
        view_helper
    )
    receipts_holder, _ = deploy_upgradeable_contract(
        deploy_parameters,
        ReceiptsHolder,
        "__ReceiptsHolder_init",
        proxy_admin,
        vault,
        token1,
        token2,
        bin_step,
        router,
        pool.receipt_token,
        view_helper
    )

    pool.vault = vault
    strategy, _ = deploy_upgradeable_contract(
        deploy_parameters,
        Strategy,
        "__Strategy_init_",
        proxy_admin,
        vault,
    )
    vault.setReceiptsManager(receipts_holder, deploy_parameters)
    pool.strategy = strategy
    vault.setStrategy(strategy, deploy_parameters)
    vault.setSwapMinimumThreshold(10**17, deploy_parameters)
    vault.setSwapMaxValue(10**17, deploy_parameters)
    vault.setDeltaSwapSafeguard(10, deploy_parameters)
    strategy.setManager(strategy_owner, deploy_parameters)
    strategy.setManager(strategy_owner, deploy_parameters)
    receipts_holder.setStrategy(strategy, deploy_parameters)
    # oracle, _ = deploy_upgradeable_contract(
    #     deploy_parameters,
    #     Oracle,
    #     "__Oracle_init",
    #     proxy_admin,
    # )
    oracle = OracleHelper.deploy(deploy_parameters)
    with no_connect_deployment() as dep:
        token_1_infos, token_2_infos = dep.get_tokens_for_joe_lb(pool)
    for infos in [token_1_infos, token_2_infos]:
        if infos.is_stable:
            oracle.setIsStable(infos.address, True, deploy_parameters)
        if infos.feed is not None:
            oracle.setFeedForToken(infos.address, infos.feed, deploy_parameters)
    vault.setOracle(oracle, deploy_parameters)
    # oracle.setPrice(10**18, deploy_parameters)


def main(deployment: DeploymentMap, strategist, pool_contracts):
    setup_pool(deployment, pool_contracts, strategist)
    return


@pytest.fixture(scope="package")
def deployment():
    yield get_deployment(from_cache=False)


@pytest.fixture(scope="module", autouse=True)
def user1(deployment: DeploymentMap, pool_contracts):
    user = accounts[0]
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    write_balance(tokenX, user, Wei("1000 ether"))
    write_balance(tokenY, user, Wei("1000 ether"))
    return user


@pytest.fixture(scope="package", autouse=True)
def strategist(deployment: DeploymentMap):
    return accounts[-1]


@pytest.fixture(scope="module", autouse=True)
def user2(deployment: DeploymentMap, pool_contracts):
    user = accounts[1]
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    write_balance(tokenX, user, Wei("1000 ether"))
    write_balance(tokenY, user, Wei("1000 ether"))
    return user


@pytest.fixture(scope="package", autouse=True)
def module_upgrade_to_current_state():
    mass_upgrade_to_current_state()


@pytest.fixture(scope="package", autouse=True)
def main_setup(package_isolation, deployment: DeploymentMap, strategist, pool_contracts: JoeLBPool):
    main(deployment, strategist, pool_contracts)


@pytest.fixture(scope="function", autouse=True)
def isolation(
     simple_isolation,
):  # TO BE REPLACED BY py_vector.common.testing simple_isolation if issues
    pass
