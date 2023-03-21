from sys import intern

import pytest
from brownie import ZERO_ADDRESS, ReceiptsHolder, Wei, accounts, chain, interface, multicall, reverts
from brownie.project import new
from py_vector.common import DAY, HOUR, YEAR
from py_vector.common.misc import in_units, of
from py_vector.common.testing import debug_decorator
from py_vector.common.upgrades.storage import write_balance
from py_vector.vector.mainnet import DeploymentMap, get_deployment
from py_vector.vector.mainnet.deployment_map import JoeLBPool
from pydantic.utils import ValueItems
from pytest import approx


BIN_ONE_FOR_ONE = 8_388_608  # 2**23

delta_ids = [-2, -1, 0, 1]
distribution_X = [0, 0, 5 * 10**17, 5 * 10**17]
distribution_Y = [5 * 10**17, 5 * 10**17, 0, 0]


@pytest.fixture(scope="module")
def view_helper(pool_contracts):
    return interface.IViewHelper(pool_contracts.vault.viewHelper())


def deposit_user(amountA, amountB, tokenX, tokenY, user_params, vault):
    inital_tokenX = tokenX.balanceOf(vault)
    inital_tokenY = tokenY.balanceOf(vault)
    tokenX.approve(vault, amountA, user_params)
    tokenY.approve(vault, amountB, user_params)
    vault.deposit(amountA, amountB, user_params)
    # Due to harvest, value can increase.
    assert tokenX.balanceOf(vault) - inital_tokenX >= amountA
    assert tokenY.balanceOf(vault) - inital_tokenY >= amountB


def set_dummy_strategy(strategy, strategist_params):
    strategy.setParams(delta_ids, distribution_X, distribution_Y, False, False, strategist_params)
    return (0 in delta_ids)


def compute_value_based_on_active_bin_tokenX(user, deployment, pool_contracts):
    pool = pool_contracts.pool_v2
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    infos = pool.getReservesAndId()
    active_bin = infos[2]
    price = get_price_from_active_bin(active_bin, pool_contracts.bin_step)
    return (
        tokenX.balanceOf(user)
        + int(tokenY.balanceOf(user) * price)
    )


def compute_value_based_on_active_bin_tokenY(user, deployment, pool_contracts):
    pool = pool_contracts.pool_v2
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    infos = pool.getReservesAndId()
    active_bin = infos[2]
    price = get_price_from_active_bin(active_bin, pool_contracts.bin_step)
    return (
        tokenX.balanceOf(user) // price
        + tokenY.balanceOf(user)
    )


def get_active_bin(pool_contracts):
    pool = pool_contracts.pool_v2
    infos = pool.getReservesAndId()
    return infos[2]


def move_active_bin(
    deployment: DeploymentMap,
    pool_contracts: JoeLBPool,
    bin_delta,
    performing_account=None,
    active_ratio=0.5,
):
    if performing_account is None:
        performing_account = accounts[7]
    pool = pool_contracts.pool_v2
    swap_size = 0
    is_toward_Y = bin_delta < 0
    infos = pool.getReservesAndId()
    reserve_to_buy = infos[int(is_toward_Y)]
    active_bin = infos[2]
    final_bin = active_bin + bin_delta
    bins_to_query = list(range(active_bin, final_bin, -1 if is_toward_Y else 1))
    reserves = get_reserves_for_bins(pool, bins_to_query + [final_bin])
    for bin in bins_to_query:
        reserve_to_buy = reserves[bin][int(is_toward_Y)]
        price = get_price_from_active_bin(bin, pool_contracts.bin_step)
        if not is_toward_Y:
            swap_size += int(reserve_to_buy * price)
        else:
            swap_size += int(reserve_to_buy // price)

    reserve_to_buy = reserves[final_bin][int(is_toward_Y)]
    price = get_price_from_active_bin(final_bin, pool_contracts.bin_step)
    if not is_toward_Y:
        swap_size += int(reserve_to_buy * price * active_ratio)
    else:
        swap_size += int(reserve_to_buy * active_ratio // price)
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    token = tokenX if not is_toward_Y else tokenY
    other_token = tokenX if is_toward_Y else tokenY
    # swap_size = swap_size * of * other_token * in_units * token
    if other_token.balanceOf(performing_account) < swap_size:
        write_balance(other_token, performing_account, swap_size)
    router = deployment.JOE.LB.ROUTER
    other_token.approve(router, swap_size, {"from": performing_account})
    router.swapExactTokensForTokens(
        swap_size,
        0,
        [pool_contracts.bin_step],
        [other_token, token],
        performing_account,
        chain.time() + HOUR,
        {"from": performing_account},
    )
    infos = pool.getReservesAndId()
    reached_bin = infos[2]

    return swap_size, reached_bin


def get_reserves_for_bins(pair, bins):
    # with multicall(block_identifier=chain[-1]["number"]):
    reserves = [pair.getBin(bin) for bin in bins]
    return {bin_id: reserve for bin_id, reserve in zip(bins, reserves)}


def get_price_from_active_bin(bin_id, bin_step):
    relative_id = bin_id - BIN_ONE_FOR_ONE
    return (1 + (bin_step / 1e4)) ** relative_id


def normalized_value(token_X_qty, token_Y_qty, price_of_X_in_Y):
    return token_X_qty * price_of_X_in_Y // 10**18 + token_Y_qty


def test_move_active(deployment, pool_contracts):
    bin_delta = 3
    pool = pool_contracts.pool_v2
    is_down = bin_delta < 0
    active_bin = get_active_bin(pool_contracts)
    final_bin = active_bin + bin_delta
    _, reached_bin = move_active_bin(deployment, pool_contracts, bin_delta)
    new_reserves = pool.getBin(reached_bin)
    vault = pool_contracts.vault
    price = vault.getPriceFromActiveBin()
    assert pool.getReservesAndId()[2] == reached_bin
    assert approx(new_reserves[1] / normalized_value(*new_reserves[:2], price), abs=0.02) == 0.5
    assert get_reserves_for_bins(pool, [active_bin])[active_bin][int(is_down)] == 0
    _, reached_bin = move_active_bin(deployment, pool_contracts, active_bin - reached_bin)
    new_reserves = pool.getBin(reached_bin)
    assert pool.getReservesAndId()[2] == active_bin


def test_init(deployment: DeploymentMap, user1, pool_contracts):
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    assert tokenX.balanceOf(user1) > 0
    assert tokenY.balanceOf(user1) > 0
    assert vault.pair() == pool_contracts.pool_v2


def test_move_withdraw_with_deposited_liquidity(
    deployment: DeploymentMap, user1, user2, strategist, pool_contracts, view_helper
):
    user1_params = {"from": user1}
    user2_params = {"from": user2}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    amountA_user1 = 1 * of * tokenX
    amountB_user1 = 1 * of * tokenY
    active_bin = get_active_bin(pool_contracts)

    ReceiptsHolder.at(vault.receiptsManager())
    user1_value_before = compute_value_based_on_active_bin_tokenX(user1, deployment, pool_contracts)
    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)

    set_dummy_strategy(strategy, strategist_params)

    strategy.addAllLiquidity(False, strategist_params)

    assert tokenX.balanceOf(vault) == 0
    assert tokenY.balanceOf(vault) == 0

    price = vault.getPriceFromActiveBin()
    funds = vault.getTotalFunds()
    value_after_deposit = normalized_value(*vault.getTotalFunds(), price)

    _, reached_bin = move_active_bin(deployment, pool_contracts, -1)

    reserves = vault.getTotalFunds()
    before_withdraw_balance_X = tokenX.balanceOf(user1)
    before_withdraw_balance_Y = tokenY.balanceOf(user1)
    reserves = view_helper.getMaximumWithdrawalTokenYWithoutSwapping(vault, user1, user1_params)
    vault.withdraw(reserves[0], reserves[1], False, user1_params)
    with reverts():
        vault.withdraw(0, 1, False, user1_params)
    obtained_during_withdraw_balance_X = tokenX.balanceOf(user1) - before_withdraw_balance_X
    obtained_during_withdraw_balance_Y = tokenY.balanceOf(user1) - before_withdraw_balance_Y
    _, reached_bin = move_active_bin(deployment, pool_contracts, active_bin - reached_bin)
    price = vault.getPriceFromActiveBin()
    assert approx(normalized_value(obtained_during_withdraw_balance_X, obtained_during_withdraw_balance_Y, price), rel=1e-4) == \
        approx(value_after_deposit, rel=1e-4)
    # assert approx(compute_value_based_on_active_bin_tokenX(user1, deployment, pool_contracts)) == approx(user1_value_before)


def test_move_withdraw_with_deposited_liquidity_by_shares(
    deployment: DeploymentMap, user1, user2, strategist, pool_contracts, view_helper
):
    user1_params = {"from": user1}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    amountA_user1 = 1 * of * tokenX
    amountB_user1 = 1 * of * tokenY
    active_bin = get_active_bin(pool_contracts)

    user1_value_before = compute_value_based_on_active_bin_tokenX(user1, deployment, pool_contracts)
    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)

    set_dummy_strategy(strategy, strategist_params)

    strategy.addAllLiquidity(False, strategist_params)

    assert tokenX.balanceOf(vault) == 0
    assert tokenY.balanceOf(vault) == 0

    price = vault.getPriceFromActiveBin()
    funds = vault.getTotalFunds()
    value_after_deposit = normalized_value(*vault.getTotalFunds(), price)

    _, reached_bin = move_active_bin(deployment, pool_contracts, -1)

    before_withdraw_balance_X = tokenX.balanceOf(user1)
    before_withdraw_balance_Y = tokenY.balanceOf(user1)
    vault.withdrawByShares(vault.balanceOf(user1), False, user1_params)
    with reverts('ERC20: burn amount exceeds balance'):
        vault.withdraw(0, 1, False, user1_params)
    obtained_during_withdraw_balance_X = tokenX.balanceOf(user1) - before_withdraw_balance_X
    obtained_during_withdraw_balance_Y = tokenY.balanceOf(user1) - before_withdraw_balance_Y
    _, reached_bin = move_active_bin(deployment, pool_contracts, active_bin - reached_bin)
    price = vault.getPriceFromActiveBin()
    assert approx(normalized_value(obtained_during_withdraw_balance_X, obtained_during_withdraw_balance_Y, price), rel=1e-4) == \
        approx(value_after_deposit, rel=1e-4)
    # assert approx(compute_value_based_on_active_bin_tokenX(user1, deployment, pool_contracts)) == approx(user1_value_before)


def test_claim_fees(
    deployment: DeploymentMap, user1, user2, strategist, pool_contracts
):
    user1_params = {"from": user1}
    user2_params = {"from": user2}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    amountA_user1 = 1 * of * tokenX
    amountB_user1 = 1 * of * tokenY
    active_bin = get_active_bin(pool_contracts)
    initial_balanceA_strategist = tokenX.balanceOf(strategist)
    initial_balanceB_strategist = tokenY.balanceOf(strategist)
    initial_balanceA_user2 = tokenX.balanceOf(user2)
    initial_balanceB_user2 = tokenY.balanceOf(user2)
    initial_balanceA_user6 = tokenX.balanceOf(accounts[6])
    initial_balanceB_user6 = tokenY.balanceOf(accounts[6])
    user1_value_before = compute_value_based_on_active_bin_tokenX(user1, deployment, pool_contracts)
    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)

    set_dummy_strategy(strategy, strategist_params)

    strategy.addAllLiquidity(False, strategist_params)

    assert tokenX.balanceOf(vault) == 0
    assert tokenY.balanceOf(vault) == 0
    strategy.setCallerFee(400, strategist_params)
    strategy.setManagerFee(400, strategist_params)
    deploy_parameters = deployment.ACCOUNTS.deployer.parameters()
    interface.IReceiptsHolder(vault.receiptsManager()).setProtocolFee(400, deploy_parameters)
    interface.IReceiptsHolder(vault.receiptsManager()).setProtocolFeeRecipient(accounts[6], deploy_parameters)
    _, reached_bin = move_active_bin(deployment, pool_contracts, 100)
    _, reached_bin = move_active_bin(deployment, pool_contracts, active_bin - reached_bin)
    _, reached_bin = move_active_bin(deployment, pool_contracts, -100)
    _, reached_bin = move_active_bin(deployment, pool_contracts, active_bin - reached_bin)

    reserves = vault.getTotalFunds()
    vault.harvest(user2, user2_params)
    assert tokenX.balanceOf(user2) > initial_balanceA_user2
    assert tokenY.balanceOf(user2) > initial_balanceB_user2
    assert tokenX.balanceOf(strategist) > initial_balanceA_strategist
    assert tokenY.balanceOf(strategist) > initial_balanceB_strategist
    assert tokenX.balanceOf(accounts[6]) > initial_balanceA_user6
    assert tokenY.balanceOf(accounts[6]) > initial_balanceB_user6


def test_move_neutral_withdraw_with_deposited_liquidity(
    deployment: DeploymentMap, user1, user2, strategist, pool_contracts, view_helper
):
    user1_params = {"from": user1}
    user2_params = {"from": user2}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    amountA_user1 = 1 * of * tokenX
    amountB_user1 = 1 * of * tokenY
    active_bin = get_active_bin(pool_contracts)
    initial_balanceA = tokenX.balanceOf(user1)
    initial_balanceB = tokenY.balanceOf(user1)

    def user_value(user, price):
        return normalized_value(tokenX.balanceOf(user), tokenY.balanceOf(user), price)

    price = vault.getPriceFromActiveBin()
    user1_value_before = user_value(user1, price)

    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)

    set_dummy_strategy(strategy, strategist_params)

    strategy.addAllLiquidity(False, strategist_params)

    assert tokenX.balanceOf(vault) == 0
    assert tokenY.balanceOf(vault) == 0

    _, reached_bin = move_active_bin(deployment, pool_contracts, 100)

    _, reached_bin = move_active_bin(deployment, pool_contracts, active_bin - reached_bin)
    funds = vault.getTotalFunds()
    reserves = view_helper.getMaximumWithdrawalTokenYWithoutSwapping(vault, user1)
    vault.withdraw(reserves[0], reserves[1], False, user1_params)
    assert approx(vault.balanceOf(user2) // 10**18) == approx(0)
    assert approx(tokenX.balanceOf(user1)) == approx(initial_balanceA - amountA_user1 + funds[0])
    assert approx(tokenY.balanceOf(user1)) == approx(initial_balanceB - amountB_user1 + funds[1])
    assert approx(user_value(user1, price)) == approx(user1_value_before)


def test_move_side_depleted_withdraw_with_deposited_liquidity(
    deployment: DeploymentMap, user1, user2, strategist, pool_contracts, view_helper
):
    bin_movement = 5
    user1_params = {"from": user1}
    user2_params = {"from": user2}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    amountA_user1 = 1 * of * tokenX
    amountB_user1 = 1 * of * tokenY
    active_bin = get_active_bin(pool_contracts)
    initial_balanceA = tokenX.balanceOf(user1)
    initial_balanceB = tokenY.balanceOf(user1)
    user1_value_before = compute_value_based_on_active_bin_tokenX(user1, deployment, pool_contracts)
    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)

    set_dummy_strategy(strategy, strategist_params)

    strategy.addAllLiquidity(False, strategist_params)

    price = vault.getPriceFromActiveBin()
    funds = vault.getTotalFunds()
    value_after_deposit = normalized_value(*funds, price)
    assert tokenX.balanceOf(vault) == 0
    assert tokenY.balanceOf(vault) == 0

    _, reached_bin = move_active_bin(deployment, pool_contracts, bin_movement)

    before_withdraw_balance_X = tokenX.balanceOf(user1)
    before_withdraw_balance_Y = tokenY.balanceOf(user1)
    reserves = view_helper.getMaximumWithdrawalTokenYWithoutSwapping(vault, user1)
    vault.withdraw(reserves[0], reserves[1], False, user1_params)
    price_at_withdrawal = vault.getPriceFromActiveBin()
    obtained_during_withdraw_balance_X = tokenX.balanceOf(user1) - before_withdraw_balance_X
    obtained_during_withdraw_balance_Y = tokenY.balanceOf(user1) - before_withdraw_balance_Y
    _, reached_bin = move_active_bin(deployment, pool_contracts, active_bin - reached_bin)
    assert vault.getSharesForDepositTokens(2, vault.getOraclePrice()) >= vault.balanceOf(user1)
    value_given_back = normalized_value(obtained_during_withdraw_balance_X, obtained_during_withdraw_balance_Y, price_at_withdrawal)
    assert approx(value_given_back, rel=5e-4) == approx(value_after_deposit, rel=5e-4) or value_given_back > value_after_deposit
    # assert approx(compute_value_based_on_active_bin_tokenX(user1, deployment, pool_contracts)) == approx(user1_value_before)


def test_move_deposit_during_move_withdraw_with_deposited_liquidity(
    deployment: DeploymentMap, user1, user2, strategist, pool_contracts
):
    bin_movement = 5
    user1_params = {"from": user1}
    user2_params = {"from": user2}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    amountA_user1 = 1 * of * tokenX
    amountB_user1 = 1 * of * tokenY
    active_bin = get_active_bin(pool_contracts)
    initial_balanceA = tokenX.balanceOf(user1)
    initial_balanceB = tokenY.balanceOf(user1)
    view_helper = interface.IViewHelper(vault.viewHelper())

    def user_value(user, price):
        return normalized_value(tokenX.balanceOf(user), tokenY.balanceOf(user), price)

    price = vault.getOraclePrice()

    user1_value_before = user_value(user1, price)
    user2_value_before = user_value(user2, price)
    # user2_value_before = compute_value_based_on_active_bin_tokenX(user2, deployment, pool_contracts)

    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)

    set_dummy_strategy(strategy, strategist_params)
    strategy.addAllLiquidity(False, strategist_params)
    value_in_vault = normalized_value(*vault.getTotalFunds(), price)
    value_1_after_deposit = user_value(user1, price) + value_in_vault
    assert tokenX.balanceOf(vault) == 0
    assert tokenY.balanceOf(vault) == 0
    (initialValueX, initialValueY) = view_helper.getMaximumWithdrawalTokenYWithoutSwapping(vault, user1, user1_params)
    _, reached_bin = move_active_bin(deployment, pool_contracts, bin_movement)
    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user2_params, vault)
    (valueX, valueY) = view_helper.getMaximumWithdrawalTokenYWithoutSwapping(vault, user1, user1_params)
    assert valueY > initialValueY or valueX > initialValueX
    strategy.addAllLiquidity(False, strategist_params)
    value_2_after_deposit = normalized_value(*vault.getTotalFunds(), price) - value_in_vault

    _, reached_bin = move_active_bin(deployment, pool_contracts, active_bin - reached_bin)

    funds = vault.getTotalFunds()
    price_oracle = vault.getOraclePrice()

    (valueX, _) = view_helper.getMaximumWithdrawalTokenXWithoutSwapping(vault, user1, user1_params)
    vault.withdraw(valueX, 0, False, user1_params)
    # Gamification : Voir si le user2 n'a pas de edge apres avoir effectué dépot, move, dépot

    (_, valueY) = view_helper.getMaximumWithdrawalTokenYWithoutSwapping(vault, user1, user1_params)
    if valueY > 0:
        vault.withdraw(0, valueY, False, user1_params)
    assert approx(user_value(user1, price)) == approx(user1_value_before)
    assert vault.getSharesForDepositTokens(2, price) > vault.balanceOf(user1)
    _, reached_bin = move_active_bin(deployment, pool_contracts, bin_movement)
    reserves = view_helper.getMaximumWithdrawalTokenYWithoutSwapping(vault, user2, user2_params)
    funds = vault.getTotalFunds()
    assert funds[0] >= reserves[0] - 1
    assert funds[1] >= reserves[1] - 1
    balanceA_user2_before_withdraw = tokenX.balanceOf(user2)
    balanceB_user2_before_withdraw = tokenY.balanceOf(user2)
    vault.withdraw(reserves[0], reserves[1], False, user2_params)
    assert vault.getSharesForDepositTokens(2, price) > vault.balanceOf(user2)
    # assert normalized_value(tokenX.balanceOf(user2)-balanceA_user2_before_withdraw,
    #     tokenY.balanceOf(user2)-balanceB_user2_before_withdraw, price) >= value_2_after_deposit
    user2_value_after = user_value(user2, price)
    assert approx(user2_value_after) == approx(user2_value_before) or user2_value_after >= user2_value_before
    # assert approx(user_value(user2, price)) >= value_2_after_deposit - 1
    # assert user_value(user2, price) >= value_2_after_deposit - 1
    # TODO : Recheck this entire test it was very weird


def test_gamification_deposit_only_tokenX(
    deployment: DeploymentMap, user1, user2, strategist, pool_contracts
):
    bin_movement = 7
    user1_params = {"from": user1}
    user2_params = {"from": user2}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    amountA_user1 = 1 * of * tokenX
    amountB_user1 = 1 * of * tokenY
    active_bin = get_active_bin(pool_contracts)
    initial_balanceA = tokenX.balanceOf(user1)
    initial_balanceB = tokenY.balanceOf(user1)
    view_helper = interface.IViewHelper(vault.viewHelper())

    def user_value(user, price):
        return normalized_value(tokenX.balanceOf(user), tokenY.balanceOf(user), price)
    price = vault.getOraclePrice()
    user1_value_before = compute_value_based_on_active_bin_tokenX(user1, deployment, pool_contracts)
    user2_value_before = user_value(user2, price)
    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)

    set_dummy_strategy(strategy, strategist_params)
    strategy.addAllLiquidity(False, strategist_params)
    assert tokenX.balanceOf(vault) == 0
    assert tokenY.balanceOf(vault) == 0

    _, reached_bin = move_active_bin(deployment, pool_contracts, bin_movement)
    deposit_user(amountA_user1, 100, tokenX, tokenY, user2_params, vault)
    _, reached_bin = move_active_bin(deployment, pool_contracts, active_bin - reached_bin)
    reserves = view_helper.getMaximumWithdrawalTokenYWithoutSwapping(vault, user2, user2_params)
    vault.withdraw(reserves[0], reserves[1], False, user2_params)
    assert vault.getSharesForDepositTokens(2, price) >= vault.balanceOf(user2)
    assert approx(user_value(user2, price)) == approx(user2_value_before)
    chain.undo(1)
    reserves = view_helper.getMaximumWithdrawalTokenXWithoutSwapping(vault, user2, user2_params)
    vault.withdraw(reserves[0], reserves[1], False, user2_params)
    assert vault.getSharesForDepositTokens(2, price) > vault.balanceOf(user2)
    assert approx(user_value(user2, price)) == approx(user2_value_before)


def test_gamification_deposit_only_tokenY(
    deployment: DeploymentMap, user1, user2, strategist, pool_contracts
):
    bin_movement = 7
    user1_params = {"from": user1}
    user2_params = {"from": user2}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)
    bin_step = pool_contracts.bin_step
    amountA_user1 = 100 * of * tokenX
    amountB_user1 = 100 * of * tokenY
    active_bin = get_active_bin(pool_contracts)
    initial_balanceA = tokenX.balanceOf(user1)
    initial_balanceB = tokenY.balanceOf(user1)

    def user_value(user, price):
        return normalized_value(tokenX.balanceOf(user), tokenY.balanceOf(user), price)
    price = vault.getOraclePrice()
    user1_value_before = compute_value_based_on_active_bin_tokenX(user1, deployment, pool_contracts)
    user2_value_before = user_value(user2, price)
    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)
    # value_1st_deposit = normalized_value(*vault.getTotalFunds(), price)

    set_dummy_strategy(strategy, strategist_params)
    strategy.addAllLiquidity(False, strategist_params)
    assert tokenX.balanceOf(vault) == 0
    assert tokenY.balanceOf(vault) == 0

    _, reached_bin = move_active_bin(deployment, pool_contracts, bin_movement)
    deposit_user(100, amountB_user1, tokenX, tokenY, user2_params, vault)
    # value_2nd_deposit = normalized_value(*vault.getTotalFunds(), price) - value_1st_deposit
    _, reached_bin = move_active_bin(deployment, pool_contracts, active_bin - reached_bin)
    reserves = interface.IViewHelper(vault.viewHelper()).getMaximumWithdrawalTokenYWithoutSwapping(vault, user2, user2_params)

    vault.withdraw(reserves[0], reserves[1], False, user2_params)
    assert vault.getSharesForDepositTokens(2, price) > vault.balanceOf(user2)
    assert approx(user_value(user2, price)) == approx(user2_value_before)
    chain.undo(1)
    reserves = interface.IViewHelper(vault.viewHelper()).getMaximumWithdrawalTokenXWithoutSwapping(vault, user2, user2_params)
    vault.withdraw(reserves[0], reserves[1], False, user2_params)
    assert vault.getSharesForDepositTokens(2, price) > vault.balanceOf(user2)
    assert approx(user_value(user2, price)) == approx(user2_value_before)


def test_safeguards(
    deployment: DeploymentMap, user1, user2, strategist, pool_contracts
):
    bin_movement = 7
    user1_params = {"from": user1}
    user2_params = {"from": user2}
    strategist_params = {"from": strategist}
    strategy = pool_contracts.strategy
    vault = pool_contracts.vault
    deploy_parameters = deployment.ACCOUNTS.deployer.parameters()

    vault.setDepositThreshold(Wei('0.01 ether'), deploy_parameters)
    vault.setAddLiquidityThreshold(Wei('.01 ether'), deploy_parameters)
    vault.setSwapThreshold(Wei('.01 ether'), deploy_parameters)
    tokenX, tokenY = deployment.get_tokens_for_joe_lb(pool_contracts)

    vault.setDepositThreshold(Wei('.01 ether'), {"from": vault.owner()})
    bin_step = pool_contracts.bin_step
    amountA_user1 = 100 * of * tokenX
    amountB_user1 = 100 * of * tokenY
    active_bin = get_active_bin(pool_contracts)
    initial_balanceA = tokenX.balanceOf(user1)
    initial_balanceB = tokenY.balanceOf(user1)
    user1_value_before = compute_value_based_on_active_bin_tokenX(user1, deployment, pool_contracts)
    user2_value_before = compute_value_based_on_active_bin_tokenX(user2, deployment, pool_contracts)
    deposit_user(amountA_user1, amountB_user1, tokenX, tokenY, user1_params, vault)

    set_dummy_strategy(strategy, strategist_params)

    _, reached_bin = move_active_bin(deployment, pool_contracts, bin_movement)
    swap_amount = amountB_user1 / 2
    minimum_amount_expected = strategy.expectedAmount(tokenX, swap_amount)

    price_oracle = vault.getOraclePrice()
    price_bins = vault.getPriceFromActiveBin()
    deposit_threshold_to_fail = abs(price_oracle - price_bins) / price_oracle

    vault.setDepositThreshold(int(Wei('1 ether') * deposit_threshold_to_fail / 2), deploy_parameters)
    with reverts('Price out of bounds'):
        deposit_user(100, amountB_user1, tokenX, tokenY, user2_params, vault)
    vault.setDepositThreshold(Wei('.01 ether'), {"from": vault.owner()})

    vault.setAddLiquidityThreshold(int(Wei('1 ether') * deposit_threshold_to_fail / 2), deploy_parameters)
    with reverts('Price out of bounds'):
        strategy.addAllLiquidity(False, strategist_params)
    vault.setAddLiquidityThreshold(Wei('.01 ether'), {"from": vault.owner()})

    with reverts('Only if under swapMinimumThreshold'):
        strategy.swap(tokenX, swap_amount, minimum_amount_expected, strategist_params)
    _, reached_bin = move_active_bin(deployment, pool_contracts, active_bin - reached_bin)
    strategy.addAllLiquidity(False, strategist_params)
    _, reached_bin = move_active_bin(deployment, pool_contracts, 2 * bin_movement)
    strategy.withdrawAllLiquidity(strategist_params)

    vault.setSwapThreshold(int(Wei('1 ether') * deposit_threshold_to_fail / 2), deploy_parameters)
    with reverts('Price out of bounds'):
        swap_amount = amountB_user1 / 10
        minimum_amount_expected = strategy.expectedAmount(tokenX, swap_amount)
        strategy.swap(tokenX, swap_amount, minimum_amount_expected, strategist_params)
    vault.setSwapThreshold(Wei('.05 ether'), deploy_parameters)

    vault.setSwapMaxValue(10**15, deploy_parameters)
    with reverts("Only a swapMaxValue swap"):
        strategy.swap(tokenX, swap_amount, minimum_amount_expected, strategist_params)
