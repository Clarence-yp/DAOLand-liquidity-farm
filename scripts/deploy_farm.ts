import config from '../config'
import { ethers, network } from 'hardhat'
import { Farming } from '../typechain'

const {
	REWARDS_PER_EPOCH,
	EPOCH_DURATION,
	FINE_DURATION,
	FINE_PERCENTAGE,
	START_TIME
} = config

async function main() {

	// let startTime = START_TIME;
	let startTime = Math.round(Date.now() / 1000) + 60;
	console.log('startTime', startTime)

	const { DLS_ADDRESS, DLD_ADDRESS } = config[network.name]

	const Farming = await ethers.getContractFactory('Farming')
	const farming = await Farming.deploy(
		REWARDS_PER_EPOCH,
		startTime,
		EPOCH_DURATION,
		FINE_DURATION,
		FINE_PERCENTAGE,
		DLD_ADDRESS,
		DLS_ADDRESS
	) as Farming

	console.log(`farming has been deployed to: ${farming.address}`);
}

main()
.then(() => process.exit(0))
.catch(error => {
	console.error(error);
	process.exit(1);
});
