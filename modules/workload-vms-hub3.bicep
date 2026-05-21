// =============================================================================
// Workload VMs Module - Hub3 Test VMs for connectivity validation
// =============================================================================
// Creates Ubuntu VMs in:
// - Spoke 5 workloads subnet (10.120.1.0/24) connected to hub3
// - Spoke 6 workloads subnet (10.220.1.0/24) connected to hub3
// =============================================================================

param location string
param adminUsername string
@secure()
param adminPassword string
param vmSize string = 'Standard_B2s'
param spoke5SubnetId string
param spoke6SubnetId string

// =============================================================================
// Spoke 5 Workload VM
// =============================================================================
resource spoke5Nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'spoke5-vm-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.120.1.10'
          subnet: {
            id: spoke5SubnetId
          }
        }
      }
    ]
  }
}

resource spoke5Vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'spoke5-vm'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: 'spoke5-vm'
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: spoke5Nic.id
        }
      ]
    }
  }
}

// =============================================================================
// Spoke 6 Workload VM
// =============================================================================
resource spoke6Nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'spoke6-vm-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.220.1.10'
          subnet: {
            id: spoke6SubnetId
          }
        }
      }
    ]
  }
}

resource spoke6Vm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'spoke6-vm'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: 'spoke6-vm'
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Standard_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: spoke6Nic.id
        }
      ]
    }
  }
}

// =============================================================================
// Outputs
// =============================================================================
output spoke5VmPrivateIp string = spoke5Nic.properties.ipConfigurations[0].properties.privateIPAddress
output spoke6VmPrivateIp string = spoke6Nic.properties.ipConfigurations[0].properties.privateIPAddress
