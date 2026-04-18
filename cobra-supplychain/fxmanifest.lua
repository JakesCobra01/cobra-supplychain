fx_version 'cerulean'
game 'gta5'

author 'Cobra Development'
description 'Cobra Development Supply Chain & Restaurant Script'
version '1.0.0'

lua54 'yes'

shared_scripts {
    '@ox_lib/init.lua',
    'configs/*.lua',
}

client_scripts {
    'client/*.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/*.lua',
}

dependency 'jim-payments'
