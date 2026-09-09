package com.paytm.wallet.wallet;

public record GetOrCreateWalletResult(WalletResponse wallet, boolean created) {
}
