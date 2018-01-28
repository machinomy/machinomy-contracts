pragma solidity ^0.4.18;

import "zeppelin-solidity/contracts/math/SafeMath.sol";
import "zeppelin-solidity/contracts/token/StandardToken.sol";


contract TokenBroker {
    using SafeMath for uint256;

    enum ChannelState { Open, Settling, Settled }
    struct PaymentChannel {
        address sender;
        address receiver;
        address erc20Contract;
        uint256 value;
        uint settlementPeriod;
        ChannelState state;
        /* until state is invalid */
        uint until;
        uint256 payment;
    }

    mapping(bytes32 => PaymentChannel) channels;
    uint32 chainId;
    uint32 id;

    event DidCreateChannel(bytes32 channelId, address indexed sender, address indexed receiver, uint256 value, uint settlementPeriod, uint until);
    event DidDeposit(bytes32 indexed channelId, uint256 value);
    event DidStartSettle(bytes32 indexed channelId, uint256 payment);
    event DidSettle(bytes32 indexed channelId, uint256 payment, uint256 oddValue);

    function TokenBroker(uint32 _chainId) public {
        chainId = _chainId;
        id = 0;
    }

    /* Create payment channel */
    function createChannel(address erc20Contract, address receiver, uint duration, uint settlementPeriod, uint256 value) public returns(bytes32) {
        var channelId = keccak256(block.number.add(id++)); // solium-disable-line
        var sender = msg.sender;
        var c = StandardToken(erc20Contract);
        require(c.transferFrom(sender, address(this), value));

        channels[channelId] = PaymentChannel(
            sender,
            receiver,
            erc20Contract,
            value,
            settlementPeriod,
            ChannelState.Open,
            block.timestamp.add(duration), // solium-disable-line
            0);
        DidCreateChannel(channelId, sender, receiver, value, settlementPeriod, block.timestamp.add(duration)); // solium-disable-line

        return channelId;
    }

    /* Add funds to the channel */
    // function deposit(bytes32 channelId, uint256 value) public {
    function deposit(bytes32 channelId, uint value) public {
        require(canDeposit(msg.sender, channelId));

        var channel = channels[channelId];
        var token = StandardToken(channel.erc20Contract);
        require(token.transferFrom(channel.sender, address(this), value));

        channel.value = channel.value.add(value);

        DidDeposit(channelId, value);
    }

    function claim(bytes32 channelId, uint256 payment, uint8 v, bytes32 r, bytes32 s) public {
        if (!canClaim(channelId, payment, v, r, s)) {
            return;
        }

        settle(channelId, payment);
    }

    /* Sender starts settling */
    function startSettle(bytes32 channelId, uint256 payment) public {
        require(canStartSettle(msg.sender, channelId));
        var channel = channels[channelId];
        channel.state = ChannelState.Settling;
        channel.until = now.add(channel.settlementPeriod); // solium-disable-line
        channel.payment = payment;
        DidStartSettle(channelId, payment);
    }

    /* Sender settles the channel, if receiver have not done that */
    function finishSettle(bytes32 channelId) public {
        require(canFinishSettle(msg.sender, channelId));
        settle(channelId, channels[channelId].payment);
    }

    function close(bytes32 channelId)  public {
        var channel = channels[channelId];
        var token = StandardToken(channel.erc20Contract);
        if (channel.state == ChannelState.Settled && (msg.sender == channel.sender || msg.sender == channel.receiver)) {
            if (channel.value > 0) {
                require(token.transfer(channel.sender, channel.value));
            }
            delete channels[channelId];
        }
    }

    /******** BEHIND THE SCENES ********/

    function settle(bytes32 channelId, uint256 payment) internal {
        var channel = channels[channelId];
        uint256 paid = payment;
        uint256 oddMoney = 0;
        var token = StandardToken(channel.erc20Contract);

        if (payment > channel.value) {
            paid = channel.value;
            require(token.transfer(channel.receiver, paid));
        } else {
            require(token.transfer(channel.receiver, paid));
            oddMoney = channel.value.sub(paid);
            require(token.transfer(channel.sender, oddMoney));
        }
        channel.value = 0;

        channels[channelId].state = ChannelState.Settled;
        DidSettle(channelId, payment, oddMoney);
    }

    /******** CAN CHECKS ********/

    function canDeposit(address sender, bytes32 channelId) public constant returns(bool) {
        var channel = channels[channelId];
        // DW: Do we really need to check that only the sender is allowed to
        //     deposit?
        return channel.state == ChannelState.Open &&
            channel.sender == sender;
    }

    function canClaim(bytes32 channelId, uint256 value, uint8 v, bytes32 r, bytes32 s) public constant returns(bool) {
        var channel = channels[channelId];
        bytes memory prefix = "\x19Ethereum Signed Message:\n32";
        bytes32 hh = keccak256(channelId, value, address(this), chainId);
        bytes32 prefixedHash = keccak256(prefix, hh);
        return (channel.state == ChannelState.Open || channel.state == ChannelState.Settling) &&
        channel.sender == ecrecover(prefixedHash, v, r, s);
    }

    function canStartSettle(address sender, bytes32 channelId) public constant returns(bool) {
        var channel = channels[channelId];
        return channel.state == ChannelState.Open &&
        channel.sender == sender;
    }

    function canFinishSettle(address sender, bytes32 channelId) public constant returns(bool) {
        var channel = channels[channelId];
        return channel.state == ChannelState.Settling && (sender == channel.sender) && channel.until <= now; // solium-disable-line
    }

    /******** READERS ********/

    function getState(bytes32 channelId) public constant returns(ChannelState) {
        return channels[channelId].state;
    }

    function getUntil(bytes32 channelId) public constant returns(uint) {
        return channels[channelId].until;
    }

    function getPayment(bytes32 channelId) public constant returns(uint) {
        return channels[channelId].payment;
    }

    function isOpenChannel(bytes32 channelId) public constant returns(bool) {
        var channel = channels[channelId];
        return channel.state == ChannelState.Open && channel.until >= now; // solium-disable-line
    }
}