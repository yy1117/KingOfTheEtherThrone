// A chain-game contract that maintains a 'throne' which agents may pay to rule.
// See www.kingoftheether.com & https://github.com/kieranelby/KingOfTheEtherThrone .
// (c) Kieran Elby 2016. All rights reserved.
// v0.9.0.
// Inspired by ethereumpyramid.com and the (now-gone?) "magnificent bitcoin gem".

// This contract lives on the blockchain at TODO
// and was compiled (without optimization) with:
// TODO

contract KingOfTheEtherThrone {

    // Represents whether we managed to send a payment or not.
    enum PaymentStatus { NotApplicable, Good, Failed, Void }

    // Represents a one-time ruler of the throne.
    struct Monarch {

        // Address to which their compensation payment will be sent.
        address compensationAddress;

        // Keep a record of the tx.origin from which they claimed the
        // throne - makes finding transactions easier.
        address originAddress;

        // A name by which they wish to be known.
        // NB: Unfortunately "string" seems to expose some bugs in web3 (and also
        // opens us up poisoning with very long strings), so use bytes for now.
        // We limit the length of the name to 30 bytes when setting it.
        bytes name;

        // How much did they pay to become monarch?
        uint256 claimPrice;

        // When did their rule start?
        uint256 coronationTimestamp;

        // Did they receive their compensation payment?
        PaymentStatus compensationStatus;

        // When did we first try to pay their compensation (0 if n/a)?
        uint256 compensationTimestamp;

        // How much compensation were they paid (0 if n/a)?
        // (Or should have been paid in the case of a failed payment).
        uint256 compensationPaid;

    }

    // Represents how this throne is configured to operate.
    struct ThroneConfig {

        // The wizard is the hidden power behind the throne; they are considered
        // to occupy the throne during gaps in succession and collect fees thru:
        // - receiving claim payments that end a gap in succession;
        // - receiving a small commission fee from each claim fee payment;
        // - receiving failed payments if not claimed after a reasonable time period.
        // However, these fees are shared with the deity - see below.
        address wizardAddress;

        // However, even the wizard is sub-ordinate to the deity; as the
        // creator of the original contract the deity is the source of all
        // earthly power and receives a 50% share of the wizard's fees.
        // They also have the (hopefully never needed) power to withdraw any
        // unexpected balance that appears.
        address deityAddress;

        // How much must the first monarch pay as a claim price?
        // This also applies following the death of a monarch.
        uint256 startingClaimPrice;

        // The next claimPrice is calculated from the previous claimPrice
        // by multiplying by 1000+claimPriceAdjustPerMille then dividing by 1000.
        // For example, claimPriceAdjustPerMille=500 would cause a 50% increase.
        uint256 claimPriceAdjustPerMille;

        // How much of each claimPrice goes to the wizard and deity.
        // Expressed in 'parts per thousand' - e.g. commissionPerMille of 20 would
        // deduct 2% for the wizard + deity, leaving 98% for the previous monarch.
        uint256 commissionPerMille;

        // After what length of reign will the curse strike down the monarch?
        // Expressed in seconds.
        uint256 curseIncubationDuration;

        // How long do we keep failed payments ring-fenced before voiding them?
        uint256 failedPaymentRingfenceDuration;
    }

    // How the throne is set-up (owners, percentages, durations).
    ThroneConfig public config;

    // Used to ensure only the wizard can do some things.
    modifier onlywizard { if (msg.sender == config.wizardAddress) _ }

    // Used to ensure only the deity can do some things.
    modifier onlydeity { if (msg.sender == config.deityAddress) _ }

    // Earliest-first list of throne holders.
    Monarch[] public monarchs;

    // Keep track of the value of any failed payments - this will allow
    // us to ring-fence them in case the wizard or deity turn evil.
    uint256 ringfencedFailedPaymentsBalance;

    // Keep track of the value of fees that the wizard has accumulated
    // but not withdrawn (to save gas, they're not sent until 'swept').
    uint256 wizardBalance;

    // Create a new empty throne according to the caller's wishes.
    function KingOfTheEtherThrone(
        address wizardAddress,
        address deityAddress,
        uint256 startingClaimPrice,
        uint256 claimPriceAdjustPerMille,
        uint256 commissionPerMille,
        uint256 curseIncubationDuration,
        uint256 failedPaymentRingfenceDuration
    ) {
        // TODO - validate args for sanity
        // (though short durations sometimes make sense for testing?)
        config = ThroneConfig(
            wizardAddress,
            deityAddress,
            startingClaimPrice,
            claimPriceAdjustPerMille,
            commissionPerMille,
            curseIncubationDuration,
            failedPaymentRingfenceDuration
        );
    }

    // How many monarchs have there been (including the current one, live or dead)?
    function numberOfMonarchs() constant returns (uint numberOfMonarchs) {
        return monarchs.length;
    }

    // What was the most recent price paid to successfully claim the throne?
    function lastClaimPrice() constant returns (uint256 price) {
        return monarchs[monarchs.length - 1].claimPrice;
    }

    // How much do you need to pay right now to become the King or Queen of the Ether?
    function currentClaimPrice() constant returns (uint256 price) {
        if (!isLivingMonarch()) {
            return config.startingClaimPrice;
        } else {
            // Work out the claim fee from the last one.
            uint256 lastClaimPrice = monarchs[monarchs.length - 1].claimPrice;
            // Stop number of trailing decimals getting silly - we round it a bit.
            uint256 rawNewClaimPrice = lastClaimPrice * (1000 + config.claimPriceAdjustPerMille) / 1000;
            if (rawNewClaimPrice < 10 finney) {
                return rawNewClaimPrice;
            } else if (rawNewClaimPrice < 100 finney) {
                return 100 szabo * (rawNewClaimPrice / 100 szabo);
            } else if (rawNewClaimPrice < 1 ether) {
                return 1 finney * (rawNewClaimPrice / 1 finney);
            } else if (rawNewClaimPrice < 10 ether) {
                return 10 finney * (rawNewClaimPrice / 10 finney);
            } else if (rawNewClaimPrice < 100 ether) {
                return 100 finney * (rawNewClaimPrice / 100 finney);
            } else if (rawNewClaimPrice < 1000 ether) {
                return 1 ether * (rawNewClaimPrice / 1 ether);
            } else if (rawNewClaimPrice < 10000 ether) {
                return 10 ether * (rawNewClaimPrice / 10 ether);
            } else {
                return rawNewClaimPrice;
            }
        }
    }

    // Is the throne currently ruled by a living monarch?
    function isLivingMonarch() constant returns (bool alive) {
        if (numberOfMonarchs() == 0) {
            return false;
        }
        // TODO - how safe is it to put considerable trust in these block timestamps?
        uint256 reignStarted = monarchs[monarchs.length - 1].coronationTimestamp;
        uint256 reignDuration = now - reignStarted;
        if (reignDuration > config.curseIncubationDuration) {
            // The monarch has been struck down by the curse.
            return false;
        } else {
            return true;
        }
    }

    // Fallback function to claim the throne - simple transactions trigger this.
    // Assumes the message data is their desired name in ASCII (nameless if none).
    // The caller will need to include payment of currentClaimPrice with the transaction.
    // They will also need to include plenty of gas - 500,000 recommended.
    function() {
        claimThrone(readNameFromMsgData());
    }

    // Claim the throne in the given name.
    // The caller will need to include payment of currentClaimPrice with the transaction.
    // This function assumes that any compensation payment later due should be sent
    // to the account that called this contract (which might itself be a contract).
    // They will also need to include plenty of gas - 500,000 recommended.
    function claimThrone(bytes name) {
        claimThroneFor(name, msg.sender);
    }

    // Claim the throne in the given name, specifying an address to which any
    // compensation payment should later be sent. Don't get it wrong - can't change!
    // The caller will need to include payment of currentClaimPrice with the transaction.
    // They will also need to include plenty of gas - 500,000 recommended.
    function claimThroneFor(bytes name, address compensationAddress) {

        validateName(name);

        uint256 valuePaid = msg.value;

        uint256 correctPrice = currentClaimPrice();

        // If they paid too little, blow up - this should refund them (tho they lose all gas).
        if (valuePaid < correctPrice) {
            throw;
        }

        // If they paid too much, blow up - this should refund them (tho they lose all gas).
        // (Earlier contract versions tried to send the excess back, but
        //  that got too fiddly with the possibility of failure).
        if (valuePaid > correctPrice) {
            throw;
        }

        if (!isLivingMonarch()) {

            // When the throne is vacant, the claim price payment accumulates
            // for the wizard and deity as extra commission.
            recordCommission(correctPrice);

        } else {

            // The claim price payment goes to the current monarch as compensation,
            // with a commission held back for the wizard and deity.

            uint256 commission = (correctPrice * config.commissionPerMille) / 1000;
            uint256 compensation = correctPrice - commission;
            recordCommission(commission);

            // Sending ether to a contract address can fail if the destination
            // contract runs out of gas receiving it (or otherwise mis-behaves).
            // We include some extra gas (paid for by the current caller) to help
            // avoid failure. It might be that the current caller hasn't included
            // enough gas to even start the call - but that's OK, the next line
            // will just blow up and they will be refunded and everything undone.
            // However, if sending the payment fails, we don't throw an exception
            // since we don't want the throne to get stuck because of one badly
            // behaved contract. Instead, we record the failure and move on -
            // they can get their money back later using resendFailedPayment().
            // Experiments suggest 20000 + 2300 gas should be enough for wallets.

            uint256 compensationExtraGas = 20000;
            bool ok = sendWithExtraGas(monarchs[monarchs.length-1].compensationAddress,
                                       compensation, compensationExtraGas);
            if (ok) {
                monarchs[monarchs.length-1].compensationStatus = PaymentStatus.Good;
            } else {
                monarchs[monarchs.length-1].compensationStatus = PaymentStatus.Failed;
                ringfencedFailedPaymentsBalance += compensation;
            }
            monarchs[monarchs.length-1].compensationTimestamp = block.timestamp;
            monarchs[monarchs.length-1].compensationPaid = compensation;
        }

        monarchs.push(Monarch(
            compensationAddress,
            tx.origin,
            name,
            valuePaid,
            block.timestamp,
            PaymentStatus.NotApplicable,
            0,
            0
        ));

    }

    // TODO - DOCUMENT
    function readNameFromMsgData() internal returns (bytes name) {
        return msg.data;
    }

    // TODO - DOCUMENT
    function validateName(bytes name) internal {
        // Either web3 or the solidity ABI has problems with bytes/strings above ~32 bytes.
        // See https://github.com/ethereum/web3.js/issues/357.
        if (name.length > 30) {
            throw;
        }
        // TODO - consider checking code points are reasonable?
        // But perhaps this isn't the place to do that?
    }

    // The wizard and deity split comission 50:50. To keep them honest,
    // we must track how much the wizard has received less amount swept.
    // (We could do the same for the deity, but it would be redundant).
    function recordCommission(uint256 commission) internal {
      wizardBalance += commission / 2;
    }

    // Unfortunately destination.send() only includes a stipend of 2300 gas, which
    // isn't enough to send ether to some wallet contracts - use this to add more.
    function sendWithExtraGas(address destination, uint256 value, uint256 extraGasAmt) internal returns (bool) {
      return destination.call.value(value).gas(extraGasAmt)();
    }

    // Unfortunately destination.send() only includes a stipend of 2300 gas, which
    // isn't enough to send ether to some wallet contracts - use this to add all the
    // gas we have available, minus a reserve amount we keep back for ourselves.
    function sendWithAllOurGasExcept(address destination, uint256 value, uint256 reserveGasAmt) internal returns (bool) {
        uint gasAvail = msg.gas;
        if (gasAvail < reserveGasAmt) {
            throw;
        }
        uint extraGas = gasAvail - reserveGasAmt;
        return sendWithExtraGas(destination, value, extraGas);
    }

    // Re-send a compensation payment that previously failed, in the hope that
    // adding more gas will make it work. Anyone can call it - but payments can
    // only ever go to the original compensation address.
    function resendFailedPayment(uint monarchNumber) {
        // Only failed payments can be re-sent.
        if (monarchs[monarchNumber].compensationStatus != PaymentStatus.Failed) {
            throw;
        }
        address destination = monarchs[monarchNumber].compensationAddress;
        uint256 compensation = monarchs[monarchNumber].compensationPaid;
        // Include plenty of gas with the send (but leave some for us).
        uint reserveGas = 25000;
        bool ok = sendWithAllOurGasExcept(destination, compensation, reserveGas);
        if (!ok) {
            throw;
        }
        // No longer need to ring-fence it.
        monarchs[monarchNumber].compensationStatus = PaymentStatus.Good;
        ringfencedFailedPaymentsBalance -= compensation;
    }

    // Void a failed compensation payment and award the ether to the wizard and the deity.
    // Only the wizard or the deity can call it - and even they can only call it after
    // the failedPaymentRingfenceDuration has elapsed.
    function voidFailedPayment(uint monarchNumber) {
        // Wizard or deity only please.
        if (msg.sender != config.wizardAddress && msg.sender != config.deityAddress) {
            throw;
        }
        // Only failed payments can be voided.
        if (monarchs[monarchNumber].compensationStatus != PaymentStatus.Failed) {
            throw;
        }
        // Only old payments can be voided (gives people a chance to resend).
        uint256 failedPaymentAge = now - monarchs[monarchNumber].compensationTimestamp;
        if (failedPaymentAge < config.failedPaymentRingfenceDuration) {
            throw;
        }
        // Treat as compensation and un-ringfence.
        uint256 compensation = monarchs[monarchNumber].compensationPaid;
        ringfencedFailedPaymentsBalance -= compensation;
        recordCommission(compensation);
        // Don't let it be resent/voided again!
        monarchs[monarchNumber].compensationStatus = PaymentStatus.Void;
    }

    // Used only by the wizard to collect his commission.
    function sweepWizardCommission(uint256 amount) onlywizard {
        if (amount > wizardBalance) {
            throw;
        }
        // Include plenty of gas with the send (but leave some for us).
        uint reserveGas = 25000;
        bool ok = sendWithAllOurGasExcept(config.wizardAddress, amount, reserveGas);
        if (!ok) {
            throw;
        }
        wizardBalance -= amount;
    }

    // Used only by the deity to collect his commission.
    function sweepDeityCommission(uint256 amount) onlydeity {
        // Even the deity cannot take the wizard's funds, nor the ring-fenced failed payments.
        if (amount + wizardBalance + ringfencedFailedPaymentsBalance > this.balance) {
            throw;
        }
        // Include plenty of gas with the send (but leave some for us).
        uint reserveGas = 25000;
        bool ok = sendWithAllOurGasExcept(config.deityAddress, amount, reserveGas);
        if (!ok) {
            throw;
        }
    }

    // Used only by the wizard to transfer the contract to a successor.
    // It is probably unwise for the newWizard to be a contract.
    function switchWizard(address newWizard) onlywizard {
        config.wizardAddress = newWizard;
    }

    // Used only by the deity to transfer the contract to a successor.
    // It is probably unwise for the newDeity to be a contract.
    function switchDeity(address newDeity) onlydeity {
        config.deityAddress = newDeity;
    }

}

// Work around the "contracts can't clone themsleves" problem with this helper contract -
// which also records all the paid-for alt-thrones so we can generate web-pages for them.
contract MetaKingOfTheEtherThrone {

    // TODO - document
    address deityAddress;

    // TODO - keep official record of paid-for alt-thrones

    // TODO - throne creation price

    // TODO - document
    function MetaKingOfTheEtherThrone() {
        deityAddress = msg.sender;
    }

    // TODO - document
    // TODO - throne creation price
    function createThrone(
        address wizardAddress,
        uint256 startingClaimPrice,
        uint256 claimPriceAdjustPerMille,
        uint256 commissionPerMille,
        uint256 curseIncubationDuration
    ) returns (KingOfTheEtherThrone contractAddress) {
        // TODO - validation
        uint256 failedPaymentRingfenceDuration = 30 days;
        return new KingOfTheEtherThrone(
            wizardAddress,
            deityAddress,
            startingClaimPrice,
            claimPriceAdjustPerMille,
            commissionPerMille,
            curseIncubationDuration,
            failedPaymentRingfenceDuration
        );
    }
}
