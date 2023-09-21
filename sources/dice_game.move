// Copyright (c) Move Bet, Inc.

module move_bet::dice_game {
    use sui::object::{Self, ID,UID, uid_to_bytes};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::transfer;
    use sui::package::{Self,Publisher};
    use sui::tx_context::{Self, TxContext};
    use move_bet::drand_lib::{derive_randomness, safe_selection};

    const FEE_SCALING: u128 = 10000;
    const MAX_POOL_VALUE: u64 = 10000000000000;
    const NET_VALUE_DECIMALS:u64=1000000;
    const SCALER:u64=1000000;
    const ROLL_MAX:u64=10000;
    const PREMIUM_RATE:u64=1;

    /// Error codes
    const EGameNotInProgress: u64 = 0;
    const EGameAlreadyCompleted: u64 = 1;
    const EInvalidRandomness: u64 = 2;
    const EInvalidNumber: u64 = 3;

    /// Game status
    const IN_PROGRESS: u8 = 0;
    const CLOSED: u8 = 1;
    const COMPLETED: u8 = 2;

    #[test_only]
    /// Attempt to get the most recent created object ID when none has been created.
    const ENoIDsCreated: u64 = 1;

    /// For when empty vector is supplied into join function.
    const ENoCoins: u64 = 0;

    /// For when supplied Coin is zero.
    const EZeroAmount: u64 = 0;

    /// For when pool fee is set incorrectly.
    /// Allowed values are: [0-10000).
    const EWrongFee: u64 = 1;

    /// For when someone tries to swap in an empty pool.
    const EReservesEmpty: u64 = 2;

    /// For when initial LSP amount is zero.
    const EShareEmpty: u64 = 3;

    /// For when someone attempts to add more liquidity than u128 Math allows.
    const EPoolFull: u64 = 4;

    /// Trying to claim ownership of a type with a wrong `Publisher`.
    const ENotOwner: u64 = 0;

    struct DICE_GAME has drop {}

    struct Pool has key, store {
        id: UID,
        sui: Balance<SUI>,
        premium: u64,
        premium_rate:u64,
        net_value:u64,
        stake:u64,
        min:u64,
        bias:u64,
    }

    struct Banker has key,store{
        id: UID,
        balance:u64,
        pool_id:ID,
    }

    struct Dice has key, store {
        id: UID,
        amount:u64,
        reward:u64,
        random_number:u64,
        bet_number:u64,
        win:bool,
        status:bool,
    }

    #[allow(unused_function)]
    fun init(otw: DICE_GAME,_: &mut TxContext) {
        create_pool(1,_);
        create_pool(10,_);
        create_pool(100,_);
        create_pool(1000,_);
        // create_pool(10000,_);
        // create_pool(100000,_);
        // create_pool(1000000,_);
        package::claim_and_keep(otw, _);
    }
   
    public entry fun create_pool_(
        min:u64,
        publisher: &Publisher,
        ctx: &mut TxContext
    ) {
        assert!(package::from_package<DICE_GAME>(publisher), ENotOwner);
        create_pool(min,ctx);
    }

    public fun create_pool(
        min:u64,
        ctx: &mut TxContext
    ) {
        let pool=Pool {
            id: object::new(ctx),
            sui: balance::zero(),
            premium: 0,
            premium_rate:PREMIUM_RATE,
            net_value:NET_VALUE_DECIMALS,
            stake:0,
            min:min*1000,
            bias:100,
        };
        transfer::public_share_object(pool);
    }

    entry fun set_bias(
        pool: &mut Pool, 
        bias:u64,
        publisher: &Publisher
    )
    {
        assert!(package::from_package<DICE_GAME>(publisher), ENotOwner);
        pool.bias=bias;
    }

    entry fun set_premium_rate(
        pool: &mut Pool, 
        rate:u64,
        publisher: &Publisher
    )
    {
        assert!(package::from_package<DICE_GAME>(publisher), ENotOwner);
        pool.premium_rate=rate;
    }

    public entry fun add_liquidity_new_(
        pool: &mut Pool, sui: Coin<SUI>,
        ctx: &mut TxContext
    ) {
        let banker = Banker {
            id: object::new(ctx),
            balance: 0,
            pool_id:object::id(pool),
        };
        add_liquidity(pool, &mut banker, sui);
        transfer::public_transfer(banker, tx_context::sender(ctx));
    }

    entry fun add_liquidity_(
        pool: &mut Pool, banker:&mut Banker, sui: Coin<SUI>
    ) {
        add_liquidity(pool, banker, sui);
    }

    public fun add_liquidity(
        pool: &mut Pool, banker:&mut Banker, sui: Coin<SUI>
    ) {
        assert!(coin::value(&sui) > 0, EZeroAmount);
        assert!((coin::value(&sui)+get_amounts(pool)) <= pool.min*SCALER*10000, EZeroAmount);
        // debug::print(&SCALER);
        pool.stake=pool.stake+coin::value(&sui)/SCALER*NET_VALUE_DECIMALS/pool.net_value;
        banker.balance=banker.balance+coin::value(&sui)/SCALER*NET_VALUE_DECIMALS/pool.net_value;
        let sui_balance = coin::into_balance(sui);
        balance::join(&mut pool.sui, sui_balance);
    }

    entry fun remove_liquidity_(
        pool: &mut Pool,
        banker:&mut Banker,
        amount:u64,
        ctx: &mut TxContext
    ) {
        let sui = remove_liquidity(pool,banker,amount, ctx);
        let sender = tx_context::sender(ctx);
        transfer::public_transfer(sui, sender);
    }

    entry fun remove_all_liquidity_(
        pool: &mut Pool,
        publisher: &Publisher,
        ctx: &mut TxContext
    ) {
        assert!(package::from_package<DICE_GAME>(publisher), ENotOwner);
        let sui_remove = get_amounts(pool);
        assert!(sui_remove>0,EInvalidNumber);
        let sui = coin::take(&mut pool.sui, sui_remove, ctx);
        let sender = tx_context::sender(ctx);
        transfer::public_transfer(sui, sender);
    }

    entry fun remove_some_liquidity_(
        pool: &mut Pool,
        publisher: &Publisher,
        amount:u64,
        ctx: &mut TxContext
    ) {
        assert!(package::from_package<DICE_GAME>(publisher), ENotOwner);
        let sui_remove = get_amounts(pool);
        assert!(sui_remove>0,EInvalidNumber);
        let sui = coin::take(&mut pool.sui, amount, ctx);
        let sender = tx_context::sender(ctx);
        transfer::public_transfer(sui, sender);
    }

    public fun remove_liquidity(
        pool: &mut Pool,
        banker:&mut Banker,
        amount:u64,
        ctx: &mut TxContext
    ): Coin<SUI> {
        let sui_remove = get_amounts(pool);
        assert!(sui_remove>0,EInvalidNumber);
        assert!(sui_remove>=banker.balance,EInvalidNumber);
        pool.stake=pool.stake-amount;
        banker.balance=banker.balance-amount;
        coin::take(&mut pool.sui, amount*SCALER/NET_VALUE_DECIMALS*pool.net_value, ctx)
    }

    public fun delete_banker(banker: Banker) {
        let Banker { id, balance: _,pool_id:_} = banker;
        object::delete(id);
    }

    public fun get_amounts(pool: &Pool): u64 {
        balance::value(&pool.sui)
    }

    public entry fun bet(bet_number:u64,amount:u64,pool: &mut Pool, sui: Coin<SUI>,ctx: &mut TxContext)
    {
        assert!(coin::value(&sui) >= pool.min*SCALER, EZeroAmount);
        let sui_balance = coin::into_balance(sui);
        balance::join(&mut pool.sui, sui_balance);
        assert!(bet_number > 0, EInvalidNumber);
        assert!(bet_number < ROLL_MAX, EInvalidNumber);
        let premium=(ROLL_MAX*amount/(ROLL_MAX-bet_number)-amount)*pool.premium_rate/100;
        let dice = Dice {
            id: object::new(ctx),
            amount:amount,
            reward:ROLL_MAX*amount/(ROLL_MAX-bet_number)-premium,
            random_number:0,
            bet_number:bet_number,
            win:false,
            status:true,
        };
        assert!(dice.reward<=get_amounts(pool),EInvalidNumber);
        assert!(dice.reward>dice.amount,EInvalidNumber);
        transfer::public_transfer(dice, tx_context::sender(ctx));
    }

    public entry fun bet_complete(dice:&mut Dice,pool: &mut Pool,ctx: &mut TxContext)
    {
        assert!((dice.reward-dice.amount)>0,EInvalidNumber);
        let result_value=dice_roll(uid_to_bytes(&dice.id));
        if(result_value<=pool.bias)
        {
            dice.win=false;
        }
        else
        {
            dice.win=result_value>dice.bet_number-pool.bias;
            dice.random_number=result_value;
        };
        let fee = (ROLL_MAX*dice.amount/(ROLL_MAX-dice.bet_number)-dice.amount)*pool.premium_rate/100;
        pool.premium=pool.premium+fee/SCALER;
        pool.net_value=(get_amounts(pool)-pool.premium*SCALER)/pool.stake;
        if(dice.win==false)
        {
            dice.reward=0;
            dice.status=false;
        }
        else{
            redeem(dice,pool,ctx);
        };
    }

    public fun redeem(
        dice: &mut Dice,
        pool: &mut Pool,
        ctx: &mut TxContext)
    {
        assert!(dice.status,EGameNotInProgress);
        assert!(dice.win,EGameNotInProgress);
        assert!(dice.reward>0,EGameNotInProgress);
        dice.status=false;
        let sui_remove = get_amounts(pool);
        assert!(sui_remove>0,EInvalidNumber);
        assert!(sui_remove>=dice.reward,EInvalidNumber);
        let sui = coin::take(&mut pool.sui, dice.reward, ctx);
        let sender = tx_context::sender(ctx);
        transfer::public_transfer(sui, sender);
        pool.net_value=(get_amounts(pool)-pool.premium*SCALER)/pool.stake;
    }

    public entry fun dice_roll(randomness:vector<u8>):u64
    {
        let digest = derive_randomness(randomness);
        let result = safe_selection(ROLL_MAX, &digest);
        result
    }
}

#[test_only]

module move_bet::dice_game_tests {
    use sui::sui::SUI;
    use sui::coin::{Self, Coin, mint_for_testing as mint};
    use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};
    use sui::test_utils;
    use move_bet::dice_game::{Self,Pool,Banker,Dice};

    struct BEEP {}

    struct POOLEY has drop {}

    const SUI_AMT: u64 = 1000000000;

    const MAX_POOL_VALUE: u64 = 10000000000000;

    const MIN: u64=1000000;

    // Tests section
    #[test] fun test_init_pool() {
        let scenario = scenario();
        test_init_pool_(&mut scenario);
        test::end(scenario);
    }
    #[test] fun test_add_liquidity() {
        let scenario = scenario();
        test_add_liquidity_(&mut scenario);
        test::end(scenario);
    }
    #[test] fun test_remove_liquidity() {
        let scenario = scenario();
        test_remove_liquidity_(&mut scenario);
        test::end(scenario);
    }

    #[test] fun test_bet() {
        let scenario = scenario();
        test_bet_(&mut scenario);
        test::end(scenario);
    }

    #[test_only]
    fun burn<T>(x: Coin<T>): u64 {
        let value = coin::value(&x);
        test_utils::destroy(x);
        value
    }

    fun test_init_pool_(test: &mut Scenario) {
        let (_, theguy) = people();
        next_tx(test, theguy);
        {
            dice_game::create_pool(MIN,ctx(test));
        };
        next_tx(test, theguy);
        {
            let pool = test::take_shared<Pool>(test);
            let pool_mut = &mut pool;
            let amt_sui = dice_game::get_amounts(pool_mut);
            assert!(amt_sui == 0, 0);
            test::return_shared(pool)
        };
    }

    fun test_add_liquidity_(test: &mut Scenario) {
        test_init_pool_(test);
        let (_, theguy) = people();
        next_tx(test, theguy);
        let pool = test::take_shared<Pool>(test);
        let pool_mut = &mut pool;
        let amt_sui = dice_game::get_amounts(pool_mut);
        assert!(amt_sui == 0,3);
        dice_game::add_liquidity_new_(
            pool_mut,
            mint<SUI>(MIN*10000, ctx(test)),
            ctx(test)
        );
        let amt_sui = dice_game::get_amounts(pool_mut);
        assert!(amt_sui == MIN*10000,3);
        test::return_shared(pool);
    }

    fun test_remove_liquidity_(test: &mut Scenario) {
        test_init_pool_(test);
        let (_, theguy) = people();
        next_tx(test, theguy);
        let pool = test::take_shared<Pool>(test);
        let pool_mut = &mut pool;
        dice_game::add_liquidity_new_(
            pool_mut,
            mint<SUI>(MIN*1000000000, ctx(test)),
            ctx(test)
        );
        next_tx(test, theguy);
        let banker = test::take_from_address<Banker>(test,theguy);
        let banker_mut=&mut banker;
        let sui_reserve = dice_game::get_amounts(pool_mut);
        assert!(sui_reserve == MIN*1000000000, 3);
        next_tx(test, theguy);
        let sui = dice_game::remove_liquidity(pool_mut,banker_mut,1000000000, ctx(test));
        let sui_reserve = dice_game::get_amounts(pool_mut);
        assert!(sui_reserve == 0 , 3);
        burn(sui);
        test::return_to_address(theguy,banker);
        test::return_shared(pool);      
    }

    fun test_bet_(test: &mut Scenario) {
        test_init_pool_(test);
        let (_, theguy) = people();
        next_tx(test, theguy);
        let pool = test::take_shared<Pool>(test);
        let pool_mut = &mut pool;
        dice_game::add_liquidity_new_(
            pool_mut,
            mint<SUI>(MIN*10000000000000, ctx(test)),
            ctx(test)
        );
        next_tx(test, theguy);
        let sui_reserve = dice_game::get_amounts(pool_mut);
        assert!(sui_reserve == MIN*10000000000000, 3);
        next_tx(test, theguy);
        let sui=mint<SUI>(MIN*1000000000, ctx(test));
        dice_game::bet(5000,MIN*1000000000,pool_mut, sui,ctx(test));
        next_tx(test, theguy);
        let dice = test::take_from_address<Dice>(test,theguy);
        let dice_mut=&mut dice;
        dice_game::bet_complete(dice_mut,pool_mut,ctx(test));
        test::return_to_address(theguy,dice);
        test::return_shared(pool);
    }

    // utilities
    fun scenario(): Scenario { test::begin(@0x1) }
    fun people(): (address, address) { (@0xBEEF, @0x1337) }
}
