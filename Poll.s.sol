// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";

import "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "lib/openzeppelin-contracts/contracts/access/Ownable.sol";


contract Poll is Ownable {
    uint public start;
    uint public finish;
    PollManager.PollSettings private _settings;

    address private immutable _manager;

    uint private _totalVotes;
    int16 public quizResult = -1;

    mapping(address => mapping(uint16 => uint)) private _userVotes;
    mapping(address => bool) private _alreadyVoted;

    mapping(uint16 => uint) public optionVotes;

    string[] public options;

    constructor(PollManager.PollSettings memory settings, string[] memory _options) {
        if (settings.choiceType == ChoiceType.Quiz) {
            require(settings.rewardPolicy == RewardPolicy.ToWinners, "Quiz type must be used with winners reward policy");
            require(settings.price != 0, "Quiz type must be used with winners reward policy");
        } else {
            require(settings.rewardPolicy != RewardPolicy.ToWinners, "Winners reward policy must be used with quiz type");
        }
        if (settings.token != address(0)) {
            require(settings.price != 0, "Free poll can't be used with tokens");
        }
        _settings = settings;
        _manager = msg.sender;
        options = _options;
    }

    modifier notStarted {
        require(start == 0, "Start was already scheduled");
        _;
    }

    modifier notFinished {
        require(finish == 0, "Finish was already scheduled");
        _;
    }

    modifier finished {
        require(finish != 0 && finish <= block.timestamp, "Poll wasn't finished");
        _;
    }

    modifier pollIsActive {
        require(start <= block.timestamp && (finish == 0 || finish > block.timestamp), "Poll isn't active");
        _;
    }

    modifier optionIsCorrect(uint16 optionId) {
        require(optionId < options.length, "Incorrect option");
        _;
    }

    modifier checkSingleChoice {
        if (_settings.choiceType == ChoiceType.SingleChoice) {
            require(!_alreadyVoted[tx.origin], "User already voted");
        }
        _alreadyVoted[tx.origin] = true;
        _;
    }

    modifier isQuiz {
        require(_settings.choiceType == ChoiceType.Quiz, "Poll isn't a quiz");
        _;
    }

    function schedule(uint _start, uint _finish) external onlyOwner notStarted notFinished {
        start = _start;
        finish = _finish;
    }

    function startPoll() external onlyOwner notStarted {
        start = block.timestamp;
    }

    function finishPoll() external onlyOwner notFinished {
        finish = block.timestamp;
    }

    function voteForEther(uint16 optionId) payable external pollIsActive checkSingleChoice optionIsCorrect(optionId) {
        require(_settings.token == address(0), "Poll currency isn't ether");
        require(msg.value >= _settings.price, "Not enough ether was sent");
        if (_settings.price == 0) {
            require(_userVotes[tx.origin][optionId] == 0, "User already voted for that option");
            _userVotes[tx.origin][optionId] = 1;
            optionVotes[optionId] += 1;
            _totalVotes += 1;
        } else {
            _userVotes[tx.origin][optionId] += msg.value;
            optionVotes[optionId] += msg.value;
            _totalVotes += msg.value;
        }
        
        if (_settings.rewardPolicy == RewardPolicy.ToOwner) {
            owner().call{value: msg.value}("");
        } else if (_settings.rewardPolicy == RewardPolicy.ToManager) {
            _manager.call{value: msg.value}("");
        }
    }

    function voteForTokens(uint16 optionId, uint256 tokenAmount) external pollIsActive checkSingleChoice optionIsCorrect(optionId) {
        require(_settings.token != address(0), "Poll currency is ether");
        require(tokenAmount >= _settings.price, "Not enough tokens were sent");

        IERC20(_settings.token).transferFrom(msg.sender, address(this), tokenAmount);
        _userVotes[tx.origin][optionId] += tokenAmount;
        optionVotes[optionId] += tokenAmount;
        _totalVotes += tokenAmount;

        if (_settings.rewardPolicy == RewardPolicy.ToOwner) {
            IERC20(_settings.token).transfer(owner(), tokenAmount);
        } else if (_settings.rewardPolicy == RewardPolicy.ToManager) {
            IERC20(_settings.token).transfer(_manager, tokenAmount);
        }
    }

    function finalizeQuiz(uint16 resultId) external onlyOwner finished isQuiz {
        quizResult = int16(resultId);
        uint toOwner = 0;
        if (optionVotes[resultId] == 0) {
            toOwner = _totalVotes;
        } else {
            uint winnersReward = (_totalVotes - optionVotes[resultId]) * 4 / 5;
            toOwner = _totalVotes - (winnersReward + optionVotes[resultId]);
        }
        if (_settings.token != address(0)) {
            IERC20(_settings.token).transfer(owner(), toOwner);
        } else {
            owner().call{value: toOwner}("");
        }
    }

    function getReward() external finished isQuiz {
        require(quizResult != -1, "Quiz result wasn't announced");
        require(_alreadyVoted[tx.origin], "User already claimed reward or didn't vote");
        _alreadyVoted[tx.origin] = false;
        uint16 resultId = uint16(quizResult);
        uint winnersReward = (_totalVotes - optionVotes[resultId]) * 4 / 5;
        uint moneyToSpare = winnersReward + optionVotes[resultId];
        uint reward = moneyToSpare * _userVotes[tx.origin][resultId] / optionVotes[resultId];
        if (_settings.token != address(0)) {
            IERC20(_settings.token).transfer(tx.origin, reward);
        } else {
            tx.origin.call{value: reward}("");
        }
    }
}

enum ChoiceType {
    SingleChoice,
    MultiChoice,
    Quiz
}

enum RewardPolicy {
    ToOwner,
    ToManager,
    ToWinners
}

contract PollManager is Ownable {
    uint public rewardOwnerCreatePollPrice;
    uint public rewardManagerCreatePollPrice;
    uint public rewardWinnerCreatePollPrice;

    struct PollSettings {
        uint price;
        ChoiceType choiceType;
        address token;
        RewardPolicy rewardPolicy;
    }

    function createPoll(PollSettings calldata settings, string[] calldata options) payable external returns (address) {
        if (settings.rewardPolicy == RewardPolicy.ToOwner) {
            require(msg.value >= rewardOwnerCreatePollPrice, "Not enough ether was sent");
        } else if (settings.rewardPolicy == RewardPolicy.ToManager) {
            require(msg.value >= rewardManagerCreatePollPrice, "Not enough ether was sent");
        } else {
            require(msg.value >= rewardWinnerCreatePollPrice, "Not enough ether was sent");
        }
        Poll poll = new Poll(settings, options);
        poll.transferOwnership(tx.origin);
        return address(poll);
    }

    function setCreatePollPrice(RewardPolicy rewardPolicy, uint price) external onlyOwner {
        if (rewardPolicy == RewardPolicy.ToOwner) {
            rewardOwnerCreatePollPrice = price;
        } else if (rewardPolicy == RewardPolicy.ToManager) {
            rewardManagerCreatePollPrice = price;
        } else {
            rewardWinnerCreatePollPrice = price;
        }
    }

    function drain(uint value) external onlyOwner {
        owner().call{value: value}("");
    }

    function drainToken(address token, uint tokenAmount) external onlyOwner {
        IERC20(token).transfer(owner(), tokenAmount);
    }
}

contract HackScript is Script {
    function setUp() public { }

    function run() public {
        uint pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        console.log(me);

        vm.startBroadcast(pk);

        PollManager pollManager = new PollManager();
        pollManager.setCreatePollPrice(RewardPolicy.ToOwner, 1 gwei);
        pollManager.setCreatePollPrice(RewardPolicy.ToManager, 3 gwei);
        pollManager.setCreatePollPrice(RewardPolicy.ToWinners, 3 gwei);

        PollManager.PollSettings memory settings = PollManager.PollSettings({
            price: 0,
            choiceType: ChoiceType.MultiChoice,
            token: address(0),
            rewardPolicy: RewardPolicy.ToOwner
        });
        string[] memory options = new string[](2);
        options[0] = "first";
        options[1] = "second";

        (, bytes memory data) = address(pollManager).call{value: pollManager.rewardManagerCreatePollPrice()}(
            abi.encodeWithSignature("createPoll((uint256,uint8,address,uint8),string[])", settings, options)
        );

        console.log(address(me).balance);

        address pollAddress = abi.decode(data, (address));

        Poll poll = Poll(pollAddress);

        poll.start();

        poll.voteForEther(0);
        poll.voteForEther(1);

        console.log(address(me).balance);

        console.log(poll.optionVotes(0), poll.optionVotes(1));

        // PollManager.PollSettings memory settings = PollManager.PollSettings({
        //     price: 2 gwei,
        //     choiceType: ChoiceType.Quiz,
        //     token: address(0),
        //     rewardPolicy: RewardPolicy.ToWinners
        // });
        // string[] memory options = new string[](2);
        // options[0] = "first";
        // options[1] = "second";

        // (, bytes memory data) = address(pollManager).call{value: pollManager.rewardManagerCreatePollPrice()}(
        //     abi.encodeWithSignature("createPoll((uint256,uint8,address,uint8),string[])", settings, options)
        // );

        // console.log(address(me).balance);

        // address pollAddress = abi.decode(data, (address));

        // Poll poll = Poll(pollAddress);

        // poll.start();

        // pollAddress.call{value: 2 gwei}(abi.encodeWithSignature("voteForEther(uint16)", 0));
        // pollAddress.call{value: 5 gwei}(abi.encodeWithSignature("voteForEther(uint16)", 1));

        // poll.finishPoll();

        // console.log(address(me).balance);

        // poll.finalizeQuiz(1);

        // console.log(address(me).balance);

        // poll.getReward();

        // console.log(address(me).balance);

        // console.log(poll.optionVotes(0), poll.optionVotes(1));

        vm.stopBroadcast();
    }
}
