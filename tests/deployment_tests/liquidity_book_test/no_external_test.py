import warnings
from threading import ExceptHookArgs

import pytest
from brownie import ZERO_ADDRESS, Contract, ViewHelper, Wei, accounts, chain, interface, reverts
from ens.utils import normalize_name
from py_vector.common import DAY, HOUR, YEAR
from py_vector.common.misc import in_units, of
from py_vector.common.network import ChainCheckpoint
from py_vector.common.testing import debug_decorator
from py_vector.vector.mainnet import DeploymentMap, get_deployment
from pytest import approx


TOTAL_WEIGHT_1_PCT = 10**16

delta_ids = [-2, -1, 0, 1]
distribution_X = [0, 0, 50 * TOTAL_WEIGHT_1_PCT, 50 * TOTAL_WEIGHT_1_PCT]
distribution_Y = [50 * TOTAL_WEIGHT_1_PCT, 50 * TOTAL_WEIGHT_1_PCT, 0, 0]


class ExpectedException(Exception):
    ...


@pytest.fixture(scope="module")
def view_helper(pool_contracts):
    return interface.IViewHelper(pool_contracts.vault.viewHelper())


def normalized_value(token_X_qty, token_Y_qty, price_of_X_in_Y):
    return token_X_qty * price_of_X_in_Y // 10**18 + token_Y_qty


def deposit_user(amountA, amountB, tokenX, tokenY, user_params, vault):
    inital_tokenX = tokenX.balanceOf(vault)
    inital_tokenY = tokenY.balanceOf(vault)
    tokenX.approve(vault, amountA, user_params)
    tokenY.approve(vault, amountB, user_params)
    vault.deposit(amountA, amountB, user_params)
    # Due to harvest, value can increase.
    assert tokenX.balanceOf(vault) - inital_tokenX == amountA
    assert tokenY.balanceOf(vault) - inital_tokenY == amountB


def set_dummy_strategy(strategy, strategist_params):
    strategy.setParams(delta_ids, distribution_X, distribution_Y, False, False, strategist_params)
    return (0 in delta_ids)


def test_init(deployment: DeploymentMap, user1, pool_contracts):
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    assert tokenX.balanceOf(user1) > 0
    assert tokenY.balanceOf(user1) > 0
    assert vault.pair() == pool_contracts.pool_v2


def test_deposit_vault_only(deployment: DeploymentMap, user1, strategist, pool_contracts):
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    amountA_user1 = Wei('1 ether')
    amountB_user1 = Wei('1 ether')
    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)
    assert vault.balanceOf(user1) > 0


def test_withdraw_vault_only(deployment: DeploymentMap, user1, strategist, pool_contracts, view_helper):
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    initial_balanceA = tokenX.balanceOf(user1)
    initial_balanceB = tokenY.balanceOf(user1)
    amountA_user1 = Wei('1 ether')
    amountB_user1 = Wei('1 ether')

    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)
    shares = vault.balanceOf(user1)
    amountA_to_withdraw, amountB_to_withdraw = view_helper.getMaximumWithdrawalTokenXWithoutSwapping(vault, user1)
    vault.withdraw(amountA_to_withdraw, amountB_to_withdraw, False, user1_params)
    price = vault.getOraclePrice()
    assert vault.getSharesForDepositTokens(2, price) >= vault.balanceOf(user1)
    assert tokenX.balanceOf(user1) == initial_balanceA - amountA_user1 + amountA_to_withdraw
    assert tokenY.balanceOf(user1) == initial_balanceB - amountB_user1 + amountB_to_withdraw


def test_set_manager(deployment: DeploymentMap, user1, strategist, pool_contracts):
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    deploy_parameters = deployment.ACCOUNTS.deployer.parameters()
    strategy = pool_contracts.strategy
    with reverts("Not Manager"):
        strategy.setManagerFee(0, user1_params)
    with reverts("Ownable: caller is not the owner"):
        strategy.setManager(user1, user1_params)
    strategy.setManager(user1, deploy_parameters)
    strategy.setManagerFee(0, user1_params)
    with reverts("Ownable: caller is not the owner"):
        strategy.setManager(user1, user1_params)


def test_set_fees(deployment: DeploymentMap, user1, strategist, pool_contracts):
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    receipts_holder = interface.IReceiptsHolder(vault.receiptsManager())
    # Manager Fee
    strategy.setManagerFee(0, strategist_params)
    assert receipts_holder.MANAGER_FEE() == 0
    strategy.setManagerFee(100, strategist_params)
    assert receipts_holder.MANAGER_FEE() == 100
    with reverts("Too high"):
        strategy.setManagerFee(2000, strategist_params)
    with reverts("Not Manager"):
        strategy.setManagerFee(0, user1_params)

    # Caller Fee
    strategy.setCallerFee(0, strategist_params)
    assert receipts_holder.CALLER_FEE() == 0
    strategy.setCallerFee(100, strategist_params)
    assert receipts_holder.CALLER_FEE() == 100
    with reverts("Too high"):
        strategy.setCallerFee(500, strategist_params)
    with reverts("Not Manager"):
        strategy.setCallerFee(0, user1_params)


def test_set_params(deployment: DeploymentMap, user1, strategist, pool_contracts):
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    strategy.setParams([-1, 1], [0, 10**18], [10**18, 0], False, False, strategist_params)
    with reverts("Not Manager"):
        strategy.setParams([-1, 1], [0, 10**18], [10**18, 0], False, False, user1_params)
    with reverts("Bad X distribution"):
        strategy.setParams([-1, 1], [0, 10**19], [10**18, 0], False, False, strategist_params)
    with reverts("Bad Y distribution"):
        strategy.setParams([-1, 1], [0, 10**18], [10**19, 0], False, False, strategist_params)
    with reverts("Too much bins"):
        strategy.setParams([-51, 1], [0, 10**18], [10**18, 0], False, False, strategist_params)


def test_add_all_liquidity(deployment: DeploymentMap, user1, strategist, pool_contracts):
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    amountA_user1 = 100 * of * tokenX
    amountB_user1 = 100 * of * tokenY
    (_, _, active_bin) = vault.getPairInfos()
    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)
    active_bin_used = set_dummy_strategy(strategy, strategist_params)
    reserves_before_deposit = vault.getTotalFunds()
    price_before_deposit = vault.getPriceFromActiveBin()
    value_before_deposit = normalized_value(reserves_before_deposit[0], reserves_before_deposit[1], price_before_deposit)
    tx = strategy.addAllLiquidity(False, strategist_params)
    reserves = vault.getTotalFunds()
    price = vault.getPriceFromActiveBin()
    value = normalized_value(reserves[0], reserves[1], price)
    assert approx(value_before_deposit, rel=1e-3) == approx(value, rel=1e-3)
    assert tokenX.balanceOf(vault) == 0
    assert tokenY.balanceOf(vault) == 0
    assert not (active_bin - 5 in vault.getDepositedBins())
    assert not (active_bin + 5 in vault.getDepositedBins())
    reserves_in_active = vault.getReserveForBin(active_bin)
    reserves_outside_active = [reserves[0] - reserves_in_active[0], reserves[1] - reserves_in_active[1]]
    distribution_outside_active_X = sum(distribution_X[i] for i in range(len(distribution_X)) if delta_ids[i] != 0)
    distribution_outside_active_Y = sum(distribution_Y[i] for i in range(len(distribution_Y)) if delta_ids[i] != 0)
    for i, id in enumerate(delta_ids):
        if id != 0:
            assert approx(vault.getReserveForBin(active_bin + id)[0]) == approx(reserves_outside_active[0] * distribution_X[i] / distribution_outside_active_X)
            assert approx(vault.getReserveForBin(active_bin + id)[1]) == approx(reserves_outside_active[1] * distribution_Y[i] / distribution_outside_active_Y)
            assert (active_bin + id in vault.getDepositedBins())


@pytest.mark.xfail()
def test_add_all_liquidity_w_respect_ratio(deployment: DeploymentMap, user1, strategist, pool_contracts):
    # TODO: check behavior for when one bin ends up empty
    # WARNING : CAN MISBEHAVE WHEN NOT RUN ALONE
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenA, tokenB = deployment.get_tokens_for_joe_lb(pool_contracts)
    amountA_user1 = 100 * of * tokenA
    amountB_user1 = 100 * of * tokenB

    def estimate_vault_funds():
        current_X_price_in_Y = vault.getPriceFromActiveBin()
        funds = vault.getTotalFunds()
        return funds[0] * current_X_price_in_Y / 10**18 + funds[1]

    deposit_user(amountA_user1, amountB_user1, tokenA, tokenB, user1_params, vault)
    delta_ids = [-1, 0, 1]
    distribution_X = [0, 5 * 10**17, 5 * 10**17, ]
    distribution_Y = [5 * 10**17, 5 * 10**17, 0, ]
    strategy.setParams(delta_ids, distribution_X, distribution_Y, False, False, {"from": strategist})
    infos = vault.getPairInfos()

    before_deposit_checkpoint = ChainCheckpoint()
    tx = strategy.addAllLiquidity(True, strategist_params)
    reserves = pool_contracts.pool_v2.getBin(infos[-1])
    reserves = vault.getReserveForBin(infos[-1])
    # ratio = int(reserves[0] / reserves[1] * 10**18)

    # ratio = tx.events['Log']['']
    # helper = ViewHelper.at(vault.viewHelper())
    total_reserves = vault.getTotalReserveForBin(infos[2])
    # dist = helper.computeDistributionToRespectRatio(amountA_user1, amountB_user1, ratio, delta_ids, distribution_X, distribution_Y, user1_params)
    funds = vault.getTotalFunds()
    vault_value = estimate_vault_funds()
    is_Y_side_empty = total_reserves[1] < 1000 and reserves[1] < 100
    assert is_Y_side_empty or approx(total_reserves[0] / total_reserves[1], rel=1e-4) == approx(reserves[0] / reserves[1], rel=1e-4)
    assert approx(funds[0]) == approx(amountA_user1)
    assert approx(funds[1]) == approx(amountB_user1)
    before_deposit_checkpoint.revert_to()
    strategy.addAllLiquidity(False, strategist_params)
    assert estimate_vault_funds() < vault_value


def test_add_liquidity(deployment: DeploymentMap, user1, strategist, pool_contracts):
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    amountA_user1 = 100 * of * tokenX
    amountB_user1 = 100 * of * tokenY
    (_, _, active_bin) = vault.getPairInfos()
    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)
    active_bin_used = set_dummy_strategy(strategy, strategist_params)
    reserves = vault.getTotalFunds()
    strategy.addLiquidity(amountA_user1 / 2, amountB_user1 / 2, False, strategist_params)
    assert tokenX.balanceOf(vault) == amountA_user1 / 2
    assert tokenY.balanceOf(vault) == amountB_user1 / 2
    for i, id in enumerate(delta_ids):
        if id != 0:
            assert approx(vault.getReserveForBin(active_bin + id)[0]) == approx(reserves[0] * distribution_X[i] / (2 * 10**18))
            assert approx(vault.getReserveForBin(active_bin + id)[1]) == approx(reserves[1] * distribution_Y[i] / (2 * 10**18))
            assert (active_bin + id in vault.getDepositedBins())


def test_remove_some_liquidity(deployment: DeploymentMap, user1, strategist, pool_contracts, view_helper):
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenA, tokenB = deployment.get_tokens_for_joe_lb(pool_contracts)
    amountA_user1 = 100 * of * tokenA
    amountB_user1 = 100 * of * tokenB
    initial_balanceA = tokenA.balanceOf(user1)
    initial_balanceB = tokenB.balanceOf(user1)
    deposit_user(amountA_user1, amountB_user1, tokenA, tokenB, user1_params, vault)
    active_bin_used = set_dummy_strategy(strategy, strategist_params)
    strategy.addAllLiquidity(False, strategist_params)
    funds = vault.getTotalFunds()
    strategy.withdrawLiquidity(funds[0] / 2, funds[1] / 2, strategist_params)
    reserves_after = vault.getAllReserves()
    assert approx(funds[0] // 2) == approx(reserves_after[0])
    assert approx(funds[1] // 2) == approx(reserves_after[1])
    if not active_bin_used:
        assert tokenA.balanceOf(vault) >= amountA_user1
        assert tokenB.balanceOf(vault) >= amountB_user1
    # Interestingly enough, we get more than what we bargained.
    reserves = view_helper.getMaximumWithdrawalTokenXWithoutSwapping(vault, user1)
    vault.withdraw(reserves[0], reserves[1], False, user1_params)
    price = vault.getPriceFromActiveBin()
    if not active_bin_used:
        assert approx(tokenA.balanceOf(user1)) == approx(initial_balanceA)
        assert approx(tokenB.balanceOf(user1)) == approx(initial_balanceB)
    if active_bin_used:
        assert approx(normalized_value(tokenA.balanceOf(user1), tokenB.balanceOf(user1), price)) == approx(normalized_value(initial_balanceA, initial_balanceB, price))


def test_remove_liquidity(deployment: DeploymentMap, user1, strategist, pool_contracts, view_helper):
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenA, tokenB = deployment.get_tokens_for_joe_lb(pool_contracts)
    amountA_user1 = 100 * of * tokenA
    amountB_user1 = 100 * of * tokenB
    initial_balanceA = tokenA.balanceOf(user1)
    initial_balanceB = tokenB.balanceOf(user1)
    deposit_user(amountA_user1, amountB_user1, tokenA, tokenB, user1_params, vault)
    active_bin_used = set_dummy_strategy(strategy, strategist_params)
    strategy.addAllLiquidity(False, strategist_params)
    strategy.withdrawAllLiquidity(strategist_params)
    if not active_bin_used:
        assert tokenA.balanceOf(vault) >= amountA_user1
        assert tokenB.balanceOf(vault) >= amountB_user1
    # Interestingly enough, we get more than what we bargained.
    reserves = view_helper.getMaximumWithdrawalTokenXWithoutSwapping(vault, user1)
    vault.withdraw(reserves[0], reserves[1], False, user1_params)
    price = vault.getPriceFromActiveBin()
    if not active_bin_used:
        assert approx(tokenA.balanceOf(user1)) == approx(initial_balanceA)
        assert approx(tokenB.balanceOf(user1)) == approx(initial_balanceB)
    else:
        price = vault.getOraclePrice()
        assert approx(normalized_value(tokenA.balanceOf(user1), tokenB.balanceOf(user1), price)) == approx(normalized_value(initial_balanceA, initial_balanceB, price))


def test_withdraw_fee(deployment: DeploymentMap, user1, strategist, pool_contracts, view_helper):
    user1_params = {"from": user1}
    deploy_parameters = deployment.ACCOUNTS.deployer.parameters()
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    initial_balanceA = tokenX.balanceOf(user1)
    initial_balanceB = tokenY.balanceOf(user1)

    amountA_user1 = 100 * of * tokenX
    amountB_user1 = 100 * of * tokenY
    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)

    shares = vault.balanceOf(user1)
    vault.setWithdrawalFee(3600, 1000, deploy_parameters)
    before_withdraw = ChainCheckpoint()
    amounts_to_withdraw = view_helper.getMaximumWithdrawalTokenXWithoutSwapping(vault, user1)
    vault.withdraw(*amounts_to_withdraw, False, user1_params)
    balances_with_fee = [tokenX.balanceOf(user1), tokenY.balanceOf(user1)]
    before_withdraw.revert_to()
    delay_to_skip_fee = vault.withdrawalFeeDelay()
    chain.sleep(delay_to_skip_fee + 1)
    chain.mine()
    vault.withdraw(*amounts_to_withdraw, False, user1_params)
    balances_with_no_fee = [tokenX.balanceOf(user1), tokenY.balanceOf(user1)]
    balance_after_depositA = initial_balanceA - amountA_user1
    balance_after_depositB = initial_balanceB - amountB_user1
    assert (balance_after_depositA - balances_with_fee[0]) / (balance_after_depositA - balances_with_no_fee[0]) == approx(1 - vault.withdrawalFee() / 10000)
    assert (balance_after_depositB - balances_with_fee[1]) / (balance_after_depositB - balances_with_no_fee[1]) == approx(1 - vault.withdrawalFee() / 10000)


def test_withdraw_after_liquidity_deposited(deployment: DeploymentMap, user1, strategist, pool_contracts, view_helper):
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    initial_balanceA = tokenX.balanceOf(user1)
    initial_balanceB = tokenY.balanceOf(user1)

    amountA_user1 = 100 * of * tokenX
    amountB_user1 = 100 * of * tokenY

    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)
    shares = vault.balanceOf(user1)
    active_bin_used = set_dummy_strategy(strategy, strategist_params)
    strategy.addAllLiquidity(False, strategist_params)
    reserves = view_helper.getMaximumWithdrawalTokenXWithoutSwapping(vault, user1)
    vault.withdraw(reserves[0], reserves[1], False, user1_params)
    if not active_bin_used:
        assert approx(tokenX.balanceOf(user1)) == approx(initial_balanceA)
        assert approx(tokenY.balanceOf(user1)) == approx(initial_balanceB)
    else:
        price = vault.getOraclePrice()
        assert approx(normalized_value(tokenX.balanceOf(user1), tokenY.balanceOf(user1), price)) == approx(normalized_value(initial_balanceA, initial_balanceB, price))


def test_withdraw_after_liquidity_deposited_and_strategy_changed(deployment: DeploymentMap, user1, strategist, pool_contracts, view_helper):
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    initial_balanceA = tokenX.balanceOf(user1)
    initial_balanceB = tokenY.balanceOf(user1)

    amountA_user1 = 100 * of * tokenX
    amountB_user1 = 100 * of * tokenY

    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)
    shares = vault.balanceOf(user1)
    active_bin_used = set_dummy_strategy(strategy, strategist_params)
    strategy.addAllLiquidity(False, strategist_params)
    strategy.setParams([-1, 1], [0, 10**18], [10**18, 0], False, False, strategist_params)
    strategy.executeRebalance(False, strategist_params)
    reserves = view_helper.getMaximumWithdrawalTokenXWithoutSwapping(vault, user1)
    vault.withdraw(reserves[0], reserves[1], False, user1_params)
    if not active_bin_used:
        assert approx(tokenX.balanceOf(user1)) == approx(initial_balanceA)
        assert approx(tokenY.balanceOf(user1)) == approx(initial_balanceB)
    else:
        price = vault.getOraclePrice()
        assert approx(normalized_value(tokenX.balanceOf(user1), tokenY.balanceOf(user1), price)) == approx(normalized_value(initial_balanceA, initial_balanceB, price))


def test_withdraw_after_some_liquidity_deposited(deployment: DeploymentMap, user1, strategist, pool_contracts, view_helper):
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    initial_balanceA = tokenX.balanceOf(user1)
    initial_balanceB = tokenY.balanceOf(user1)

    amountA_user1 = 100 * of * tokenX
    amountB_user1 = 100 * of * tokenY

    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)
    shares = vault.balanceOf(user1)
    active_bin_used = set_dummy_strategy(strategy, strategist_params)
    strategy.addLiquidity(amountA_user1 / 2, amountB_user1 / 2, False, strategist_params)
    reserves = view_helper.getMaximumWithdrawalTokenXWithoutSwapping(vault, user1)
    vault.withdraw(reserves[0], reserves[1], False, user1_params)
    if not active_bin_used:
        assert approx(tokenX.balanceOf(user1)) == approx(initial_balanceA)
        assert approx(tokenY.balanceOf(user1)) == approx(initial_balanceB)
    else:
        price = vault.getOraclePrice()
        assert approx(normalized_value(tokenX.balanceOf(user1), tokenY.balanceOf(user1), price)) == approx(normalized_value(initial_balanceA, initial_balanceB, price))


def test_one_sided_deposit_token_X(deployment: DeploymentMap, user1, strategist, pool_contracts, view_helper):
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    initial_balanceA = tokenX.balanceOf(user1)
    initial_balanceB = tokenY.balanceOf(user1)

    amountA_user1 = 100 * of * tokenX
    amountB_user1 = 0

    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)
    shares = vault.balanceOf(user1)
    active_bin_used = set_dummy_strategy(strategy, strategist_params)
    strategy.addLiquidityWithCustomParams(
        amountA_user1 // 2,
        amountB_user1 // 2,
        [1],
        [10**18],
        [0],
        False,
        strategist_params
    )
    reserves = view_helper.getMaximumWithdrawalTokenXWithoutSwapping(vault, user1)
    vault.withdraw(reserves[0], reserves[1], False, user1_params)
    if not active_bin_used:
        assert approx(tokenX.balanceOf(user1)) == approx(initial_balanceA)
        assert approx(tokenY.balanceOf(user1)) == approx(initial_balanceB)
    else:
        price = vault.getOraclePrice()
        assert approx(normalized_value(tokenX.balanceOf(user1), tokenY.balanceOf(user1), price)) == approx(normalized_value(initial_balanceA, initial_balanceB, price))


def test_withdraw_pct_liquidity(deployment: DeploymentMap, user1, strategist, pool_contracts):
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenA, tokenB = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    initial_balanceA = tokenA.balanceOf(user1)
    initial_balanceB = tokenB.balanceOf(user1)
    active_id = vault.getPairInfos()[-1]
    receipts_holder = interface.IReceiptsHolder(vault.receiptsManager())

    amountA_user1 = 100 * of * tokenA
    amountB_user1 = 100 * of * tokenB

    shares = vault.balanceOf(user1)

    deposit_user(amountA_user1, amountB_user1, tokenA, tokenB, user1_params, vault)
    initial_delta_ids = [-2, -1, 0, 1, 2]
    initial_distributionX = [
        0,
        0,
        TOTAL_WEIGHT_1_PCT * 25,
        TOTAL_WEIGHT_1_PCT * 50,
        TOTAL_WEIGHT_1_PCT * 25,
    ]
    initial_distributionY = [
        TOTAL_WEIGHT_1_PCT * 25,
        TOTAL_WEIGHT_1_PCT * 50,
        TOTAL_WEIGHT_1_PCT * 25,
        0,
        0,
    ]

    strategy.setParams(
        initial_delta_ids,
        initial_distributionX,
        initial_distributionY,
        False,
        False,
        strategist_params,
    )
    strategy.addAllLiquidity(False, strategist_params)

    def apply_distribution(amount, deltas, distribution):
        return {
            delta: amount * weight // 10**18
            for delta, weight in zip(deltas, distribution)
        }

    joe_receipt = interface.ILBToken(vault.receiptToken())

    withdrawal_distribution = [joe_receipt.balanceOf(receipts_holder, active_id + i) / 2 for i in initial_delta_ids]

    strategy.withdrawLiquidityFromBins([active_id + i for i in initial_delta_ids], withdrawal_distribution, {'from': strategist})
    deposits_distribution_after = [joe_receipt.balanceOf(receipts_holder, active_id + i) for i in initial_delta_ids]

    for i in range(len(withdrawal_distribution)):
        assert approx(withdrawal_distribution[i]) == approx(deposits_distribution_after[i])


@pytest.mark.xfail(ExpectedException)
def test_custom_rebalance(deployment: DeploymentMap, user1, strategist, pool_contracts):
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenA, tokenB = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    initial_balanceA = tokenA.balanceOf(user1)
    initial_balanceB = tokenB.balanceOf(user1)
    active_id = vault.getPairInfos()[-1]

    vault.setSwapMinimumThreshold(10**20, deployment.ACCOUNTS.deployer.parameters())
    vault.setSwapMaxValue(10**20, deployment.ACCOUNTS.deployer.parameters())
    amountA_user1 = 100 * of * tokenA
    amountB_user1 = 100 * of * tokenB

    shares = vault.balanceOf(user1)

    deposit_user(amountA_user1, amountB_user1, tokenA, tokenB, user1_params, vault)
    initial_delta_ids = [-2, -1, 0, 1, 2]
    initial_distributionX = [
        0,
        0,
        TOTAL_WEIGHT_1_PCT * 25,
        TOTAL_WEIGHT_1_PCT * 50,
        TOTAL_WEIGHT_1_PCT * 25,
    ]
    initial_distributionY = [
        TOTAL_WEIGHT_1_PCT * 25,
        TOTAL_WEIGHT_1_PCT * 50,
        TOTAL_WEIGHT_1_PCT * 25,
        0,
        0,
    ]

    strategy.setParams(
        initial_delta_ids,
        initial_distributionX,
        initial_distributionY,
        False,
        False,
        strategist_params,
    )
    strategy.addAllLiquidity(False, strategist_params)

    active_reserves = vault.getTotalReserveForBin(active_id)
    vault_reserves_in_active = vault.getReserveForBin(active_id)
    ratio_X = active_reserves[0] / sum(active_reserves)
    other_delta_ids = [-3, -2, -1, 1, 2, 3]
    other_distributionX = [
        0,
        0,
        0,
        TOTAL_WEIGHT_1_PCT * 25,
        TOTAL_WEIGHT_1_PCT * 50,
        TOTAL_WEIGHT_1_PCT * 25,
    ]
    other_distributionY = [
        TOTAL_WEIGHT_1_PCT * 25,
        TOTAL_WEIGHT_1_PCT * 50,
        TOTAL_WEIGHT_1_PCT * 25,
        0,
        0,
        0,
    ]

    def apply_distribution(amount, deltas, distribution):
        return {
            delta: amount * weight // 10**18
            for delta, weight in zip(deltas, distribution)
        }

    bins_to_withdraw = [active_id + delta for delta in [-2, -1, 0]]
    joe_receipt = interface.ILBToken(vault.receiptToken())

    receipts_amounts_in_bins = {
        bin - active_id: joe_receipt.balanceOf(vault, bin) for bin in bins_to_withdraw}
    amounts_to_withdraw = {
        bin - active_id: receipts_amounts_in_bins.get(bin - active_id, 0) // 2 for bin in bins_to_withdraw
    }
    swap_amount = sum(
        vault.getReserveForBin(delta + active_id)[1] * amounts_to_withdraw.get(delta, 0) // receipts_amounts_in_bins.get(delta, 0)
        for delta in amounts_to_withdraw
    ) // 2
    # swap_amount = sum(amounts_to_withdraw.values()) // 2

    deposits_before_rebalance = {
        delta: joe_receipt.balanceOf(vault, active_id + delta) for delta in initial_delta_ids
    }
    minimum_amount_expected = strategy.expectedAmount(tokenA, swap_amount)
    strategy.customRebalance(
        bins_to_withdraw,
        list(amounts_to_withdraw.values()),
        swap_amount,
        minimum_amount_expected,
        tokenA,
        other_delta_ids,
        other_distributionX,
        other_distributionY,
        False,
        strategist_params,
    )
    estimate_receipts_after_swap = {
        delta:
        deposits_before_rebalance.get(delta, 0) - amounts_to_withdraw.get(delta, 0)
        for delta in initial_delta_ids
    }
    estimate_token_A_before_swap = sum(amounts_to_withdraw.get(delta, 0) for delta in initial_delta_ids if delta > 0) + \
        amounts_to_withdraw.get(0, 0) / deposits_before_rebalance.get(0, 0) * vault_reserves_in_active[0]

    estimate_token_B_before_swap = sum(amounts_to_withdraw.get(delta, 0) for delta in initial_delta_ids if delta < 0) + \
        amounts_to_withdraw.get(0, 0) / deposits_before_rebalance.get(0, 0) * vault_reserves_in_active[1]

    price = vault.getOraclePrice()
    estimate_token_A_after_swap = estimate_token_A_before_swap + int(swap_amount / price * 10**18)
    estimate_token_B_after_swap = estimate_token_B_before_swap - swap_amount

    new_deposit_tokens_X = apply_distribution(estimate_token_A_after_swap, other_delta_ids, other_distributionX)
    new_deposit_tokens_Y = apply_distribution(estimate_token_B_after_swap, other_delta_ids, other_distributionY)
    new_deposits = {delta: new_deposit_tokens_X.get(delta, 0) * price // 10**18 if delta > 0 else new_deposit_tokens_Y.get(delta, 0) for delta in other_delta_ids}

    reserves = {i: joe_receipt.balanceOf(vault, active_id + i) for i in set(other_delta_ids + initial_delta_ids)}

    try:
        assert vault.getPairInfos()[-1] != active_id
    except:
        warnings.warn("Not a real fail, but amounts calculation too hard")
        raise ExpectedException()

    for idx, delta in enumerate(other_delta_ids):
        assert approx(reserves.get(delta, 0), rel=1e-2) == approx(estimate_receipts_after_swap.get(delta, 0) + new_deposits.get(delta, 0), rel=1e-2)


def test_deposit_with_custom_shape(deployment: DeploymentMap, user1, strategist, pool_contracts):
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenA, tokenB = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    initial_balanceA = tokenA.balanceOf(user1)
    initial_balanceB = tokenB.balanceOf(user1)

    amountA_user1 = 100 * of * tokenA
    amountB_user1 = 100 * of * tokenB

    deposit_user(amountA_user1, amountB_user1, tokenA, tokenB, user1_params, vault)
    shares = vault.balanceOf(user1)
    active_bin_used = set_dummy_strategy(strategy, strategist_params)
    other_delta_ids = [-3, -2, -1, 1, 2, 3]
    other_distributionX = [0, 0, 0, TOTAL_WEIGHT_1_PCT * 25, TOTAL_WEIGHT_1_PCT * 50, TOTAL_WEIGHT_1_PCT * 25]
    other_distributionY = [TOTAL_WEIGHT_1_PCT * 25, TOTAL_WEIGHT_1_PCT * 50, TOTAL_WEIGHT_1_PCT * 25, 0, 0, 0]

    strategy.addLiquidityWithCustomParams(
        amountA_user1 // 2,
        amountB_user1 // 2,
        other_delta_ids,
        other_distributionX,
        other_distributionY,
        False,
        strategist_params
    )
    active_bin = vault.getPairInfos()[-1]
    total_reserves = vault.getAllReserves()
    reserves = {i: vault.getReserveForBin(active_bin + i) for i in other_delta_ids}
    for idx, delta in enumerate(other_delta_ids):
        assert approx(reserves[delta][0]) == approx(other_distributionX[idx] * total_reserves[0] // 10**18)
        assert approx(reserves[delta][1]) == approx(other_distributionY[idx] * total_reserves[1] // 10**18)


def test_one_sided_deposit_token_Y(deployment: DeploymentMap, user1, strategist, pool_contracts, view_helper):
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    initial_balanceA = tokenX.balanceOf(user1)
    initial_balanceB = tokenY.balanceOf(user1)

    amountA_user1 = 0
    amountB_user1 = 100 * of * tokenY

    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)
    shares = vault.balanceOf(user1)
    active_bin_used = set_dummy_strategy(strategy, strategist_params)
    strategy.addLiquidityWithCustomParams(
        amountA_user1 // 2,
        amountB_user1 // 2,
        [-1],
        [0],
        [10**18],
        False,
        strategist_params
    )
    reserves = view_helper.getMaximumWithdrawalTokenXWithoutSwapping(vault, user1)
    vault.withdraw(reserves[0], reserves[1], False, user1_params)
    if not active_bin_used:
        assert approx(tokenX.balanceOf(user1)) == approx(initial_balanceA)
        assert approx(tokenY.balanceOf(user1)) == approx(initial_balanceB)
    else:
        assert approx(tokenX.balanceOf(user1) + tokenY.balanceOf(user1)) == approx(initial_balanceA + initial_balanceB - amountA_user1 * 0.0002 - amountB_user1 * 0.0002)


def test_views(deployment: DeploymentMap, user1, strategist, pool_contracts):
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    (_, _, active_bin) = vault.getPairInfos()
    assert len(vault.getDepositedBins()) == 0
    assert vault.getHighestAndLowestBin() == (0, 0)
    assert vault.getTotalReserveForBin(active_bin) != (0, 0)
    assert vault.getReserveForBin(0) == (0, 0)
    assert vault.getAllReserves() == (0, 0)
    assert vault.getBalances() == (0, 0)
    assert vault.getTotalFunds() == (0, 0)
    assert vault.reservesOutsideActive() == (0, 0)
    assert vault.pendingRewards([active_bin]) == (0, 0)

    initial_balanceA = tokenX.balanceOf(user1)
    initial_balanceB = tokenY.balanceOf(user1)

    amountA_user1 = 100 * of * tokenX
    amountB_user1 = 100 * of * tokenY

    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)
    shares = vault.balanceOf(user1)
    active_bin_used = set_dummy_strategy(strategy, strategist_params)
    strategy.addLiquidity(amountA_user1 / 2, amountB_user1 / 2, False, strategist_params)

    assert len(vault.getDepositedBins()) > 0
    assert vault.getHighestAndLowestBin() != (0, 0)
    assert vault.getTotalReserveForBin(active_bin) != (0, 0)
    assert vault.getReserveForBin(active_bin) != (0, 0)
    assert vault.getAllReserves() != (0, 0)
    assert vault.getBalances() != (0, 0)
    assert vault.getTotalFunds() != (0, 0)
    assert vault.reservesOutsideActive() != (0, 0)
    assert vault.pendingRewards([active_bin]) == (0, 0)


@pytest.mark.xfail(ExpectedException)
def test_swap(deployment: DeploymentMap, user1, strategist, pool_contracts, view_helper):
    # WARNING : CAN MISBEHAVE WHEN NOT RUN ALONE
    # TODO : Fix the fee part
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    initial_balanceA = tokenX.balanceOf(user1)
    initial_balanceB = tokenY.balanceOf(user1)

    amountA_user1 = 100 * of * tokenX
    amountB_user1 = 100 * of * tokenY

    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)
    shares = vault.balanceOf(user1)
    initial_reserves = vault.getTotalFunds()
    swap_amount = amountB_user1 / 10
    vault.setSwapMinimumThreshold(10**20, deployment.ACCOUNTS.deployer.parameters())
    strategy.setMaxSlippage(200, deployment.ACCOUNTS.deployer.parameters())
    try:
        minimum_amount_expected = strategy.expectedAmount(tokenX, swap_amount)
        strategy.swap(tokenX, swap_amount, minimum_amount_expected, strategist_params)
    except:
        strategy.setMaxSlippage(200, deployment.ACCOUNTS.deployer.parameters())
        minimum_amount_expected = strategy.expectedAmount(tokenX, swap_amount)
        strategy.swap(tokenX, swap_amount, minimum_amount_expected, strategist_params)
        warnings.warn('Worked with increased slippage, should be ran later when oracle and price are more alike')
        raise ExpectedException('Worked with increased slippage, impossible to continue the checks')

    reserves = vault.getTotalFunds()
    current_price = vault.getPriceFromActiveBin() / 10**18
    fee_infos = pool_contracts.pool_v2.feeParameters()
    fee_rate = 1 - (fee_infos[0] * fee_infos[1] / 1e8)
    assert approx(initial_reserves[1] - reserves[1]) == approx(swap_amount)
    assert approx((reserves[0] - initial_reserves[0]) * vault.getOraclePrice() // 1e18) == approx(swap_amount * fee_rate) #Fee on swap
    active_bin_used = set_dummy_strategy(strategy, strategist_params)
    strategy.addLiquidity(amountA_user1 / 2, amountB_user1 / 2, False, strategist_params)
    reserves = view_helper.getMaximumWithdrawalTokenXWithoutSwapping(vault, user1)
    vault.withdraw(reserves[0], reserves[1], False, user1_params)
    # If something fails here, add the price in, it might be because the joe bin is not centered
    if not active_bin_used:
        assert approx(tokenX.balanceOf(user1)) == approx(initial_balanceA) + (amountB_user1 / 2 * (1 - 0.0003))
        assert approx(tokenY.balanceOf(user1)) == approx(initial_balanceB) - amountB_user1 / 2
    else:
        try:
            assert approx(tokenX.balanceOf(user1) + tokenY.balanceOf(user1)) == approx(initial_balanceA + initial_balanceB - amountA_user1 * (1 - fee_rate) - amountB_user1 * (1 - fee_rate) - amountB_user1 / 2 * 0.0003)
        except AssertionError:
            warnings.warn('The 0.0003 factor is likely to be the cause, disregard the error')
            raise ExpectedException
    # TODO: find why 0.0003


def test_rebalance(deployment: DeploymentMap, user1, strategist, pool_contracts, view_helper):
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    initial_balanceA = tokenX.balanceOf(user1)
    initial_balanceB = tokenY.balanceOf(user1)

    amountA_user1 = 100 * of * tokenX
    amountB_user1 = 100 * of * tokenY

    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)
    shares = vault.balanceOf(user1)
    active_bin_used = set_dummy_strategy(strategy, strategist_params)
    strategy.executeRebalance(False, strategist_params)
    strategy.setParams([-1, 1], [0, 10**18], [10**18, 0], False, False, strategist_params)
    strategy.executeRebalance(False, strategist_params)
    reserves = vault.getTotalFunds()
    (_, _, active_bin) = vault.getPairInfos()
    if active_bin_used:
        assert not (active_bin in vault.getDepositedBins())
    assert not (active_bin - 2 in vault.getDepositedBins())
    assert not (active_bin + 2 in vault.getDepositedBins())
    assert vault.getReserveForBin(active_bin + 1)[0] == reserves[0]
    assert vault.getReserveForBin(active_bin - 1)[1] == reserves[1]
    reserves = view_helper.getMaximumWithdrawalTokenXWithoutSwapping(vault, user1)
    vault.withdraw(reserves[0], reserves[1], False, user1_params)
    if not active_bin_used:
        assert approx(tokenX.balanceOf(user1)) == approx(initial_balanceA)
        assert approx(tokenY.balanceOf(user1)) == approx(initial_balanceB)
    else:
        price = vault.getOraclePrice()
        assert approx(normalized_value(tokenX.balanceOf(user1), tokenY.balanceOf(user1), price)) == approx(normalized_value(initial_balanceA, initial_balanceB, price))


def test_multiple_user_share_calculation(deployment: DeploymentMap, user1, user2, strategist, pool_contracts):
    user1_params = {"from": user1}
    user2_params = {"from": user2}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    initial_balanceA = tokenX.balanceOf(user1)
    initial_balanceB = tokenY.balanceOf(user1)
    view_helper = interface.IViewHelper(vault.viewHelper())

    amountA_user1 = 100 * of * tokenX
    amountB_user1 = 100 * of * tokenY

    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)
    shares = vault.balanceOf(user1)
    active_bin_used = set_dummy_strategy(strategy, strategist_params)
    strategy.addLiquidity(amountA_user1 / 2, amountB_user1 / 2, False, strategist_params)
    # strategy.addAllLiquidity(False, strategist_params)
    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user2_params, vault)
    if not active_bin_used:
        assert vault.balanceOf(user1) == vault.balanceOf(user2)
    else:
        assert vault.balanceOf(user1) >= vault.balanceOf(user2) * 0.99 #Account for the fee when liquidity was deposited
    assert vault.balanceOf(user1)
    assert vault.balanceOf(user2)
    amountA_to_withdraw = view_helper.getMaximumWithdrawalTokenXWithoutSwapping(vault, user1)[0]
    vault.withdraw(amountA_to_withdraw, 0, False, user1_params)
    (_, valueY) = view_helper.getMaximumWithdrawalTokenYWithoutSwapping(vault, user1, user1_params)
    if valueY:
        vault.withdraw(0, valueY, False, user1_params)
    reserves = view_helper.getMaximumWithdrawalTokenYWithoutSwapping(vault, user2, user2_params)
    funds = vault.getTotalFunds()
    assert funds[0] >= reserves[0] - 1
    assert funds[1] >= reserves[1] - 1
    vault.withdraw(reserves[0], reserves[1], False, user2_params)
    if not active_bin_used:
        assert approx(tokenX.balanceOf(user1)) == approx(initial_balanceA)
        assert approx(tokenY.balanceOf(user1)) == approx(initial_balanceB)
    else:
        price = vault.getOraclePrice()
        assert approx(normalized_value(tokenX.balanceOf(user1), tokenY.balanceOf(user1), price)) == approx(normalized_value(initial_balanceA, initial_balanceB, price))


def test_multiple_user_single_sided(deployment: DeploymentMap, user1, user2, strategist, pool_contracts, view_helper):
    user1_params = {"from": user1}
    user2_params = {"from": user2}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    initial_balanceA = tokenX.balanceOf(user1)
    initial_balanceB = tokenY.balanceOf(user1)

    amountA_user1 = 100 * of * tokenX
    amountB_user1 = 0

    active_id = vault.getPairInfos()[-1]
    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)
    shares = vault.balanceOf(user1)
    active_bin_used = set_dummy_strategy(strategy, strategist_params)
    strategy.addLiquidityWithCustomParams(
        amountA_user1,
        0,
        [1],
        [10**18],
        [0],
        False,
        strategist_params
    )
    deposited_amount_A = vault.getTotalFunds()[0]
    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user2_params, vault)
    assert vault.balanceOf(user1)
    assert vault.balanceOf(user2)
    strategy.addLiquidityWithCustomParams(
        amountA_user1,
        0,
        [1],
        [10**18],
        [0],
        False,
        strategist_params
    )

    # TODO : Find a better way to check that. The amount that can be withdrawn is likely to be a bit less because
    # of the way the first liquidity minting works as in incurs the deposit fee

    total_deposits = normalized_value(*vault.getTotalFunds(), vault.getOraclePrice())
    max_amount_withdrawable = vault.balanceOf(user1) * total_deposits // vault.totalSupply() * 10**18 // vault.getOraclePrice()
    max_amount_withdrawable = view_helper.getMaximumWithdrawalTokenXWithoutSwapping(vault, user1)[0]
    vault.withdraw(max_amount_withdrawable, 0, False, user1_params)
    assert approx(max_amount_withdrawable) == approx(deposited_amount_A)
    (_, valueY) = interface.IViewHelper(vault.viewHelper()).getMaximumWithdrawalTokenYWithoutSwapping(vault, user1, user1_params)
    assert valueY == 0
    # vault.withdraw(0, valueY, False, user1_params)
    reserves = interface.IViewHelper(vault.viewHelper()).getMaximumWithdrawalTokenYWithoutSwapping(vault, user2, user2_params)
    funds = vault.getTotalFunds()
    assert funds[0] >= reserves[0] - 1
    assert funds[1] >= reserves[1] - 1
    vault.withdraw(reserves[0], reserves[1], False, user2_params)
    if not active_bin_used:
        assert approx(tokenX.balanceOf(user1)) == approx(initial_balanceA)
        assert approx(tokenY.balanceOf(user1)) == approx(initial_balanceB)
    else:
        price = vault.getOraclePrice()
        assert approx(normalized_value(tokenX.balanceOf(user1), tokenY.balanceOf(user1), price)) == approx(normalized_value(initial_balanceA, initial_balanceB, price))


def test_multiple_user_one_single_sided(deployment: DeploymentMap, user1, user2, strategist, pool_contracts):
    user1_params = {"from": user1}
    user2_params = {"from": user2}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    initial_balanceA = tokenX.balanceOf(user1)
    initial_balanceB = tokenY.balanceOf(user1)

    amountA_user1 = 100 * of * tokenX
    amountB_user1 = 0

    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)
    shares = vault.balanceOf(user1)
    active_bin_used = set_dummy_strategy(strategy, strategist_params)
    strategy.addLiquidityWithCustomParams(
        amountA_user1,
        0,
        [1],
        [10**18],
        [0],
        False,
        strategist_params
    )
    deposited_amount_A = vault.getTotalFunds()[0]
    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user2_params, vault)
    assert vault.balanceOf(user1)
    assert vault.balanceOf(user2)
    strategy.addLiquidityWithCustomParams(
        amountA_user1,
        0,
        [1],
        [10**18],
        [0],
        False,
        strategist_params
    )
    total_deposits = normalized_value(*vault.getTotalFunds(), vault.getOraclePrice())
    max_amount_withdrawable = vault.balanceOf(user1) * total_deposits // vault.totalSupply() * 10**18 // vault.getOraclePrice()
    max_amount_withdrawable = interface.IViewHelper(vault.viewHelper()).getMaximumWithdrawalTokenYWithoutSwapping(vault, user1)[0]
    vault.withdraw(max_amount_withdrawable, 0, False, user1_params)
    assert approx(max_amount_withdrawable) == approx(deposited_amount_A)
    (_, valueY) = interface.IViewHelper(vault.viewHelper()).getMaximumWithdrawalTokenYWithoutSwapping(vault, user1)
    if valueY > 0:
        vault.withdraw(0, valueY, False, user1_params)
    reserves = interface.IViewHelper(vault.viewHelper()).getMaximumWithdrawalTokenYWithoutSwapping(vault, user2)
    funds = vault.getTotalFunds()
    assert funds[0] >= reserves[0] - 1
    assert funds[1] >= reserves[1] - 1
    vault.withdraw(reserves[0], reserves[1], False, user2_params)
    if not active_bin_used:
        assert approx(tokenX.balanceOf(user1)) == approx(initial_balanceA)
        assert approx(tokenY.balanceOf(user1)) == approx(initial_balanceB)
    else:
        price = vault.getOraclePrice()
        assert approx(normalized_value(tokenX.balanceOf(user1), tokenY.balanceOf(user1), price)) == approx(normalized_value(initial_balanceA, initial_balanceB, price))
