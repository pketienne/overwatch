# frozen_string_literal: true

name             'overwatch'
maintainer       'Patrick K. Etienne'
maintainer_email 'git@paradox.limited'
license          'All Rights Reserved'
description      'GPU-passthrough Windows gaming VM (host + guest setup)'
version          '1.0.0'

supports 'ubuntu', '>= 24.04'

depends 'symmetra_core'
depends 'libvirt'
