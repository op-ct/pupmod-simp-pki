require 'spec_helper'
require 'tmpdir'


provider_class = Puppet::Type.type(:pki_cert_sync).provider(:redhat)

def populate_cert_dir(parent_dir, cert_info)
  Dir.chdir(parent_dir) do
    cert_info.each do |file, relative_path, hash|
      dest_dir = File.join(parent_dir, relative_path)
      FileUtils.mkdir_p(dest_dir)
      FileUtils.cp(file, dest_dir)
    end
  end
end

def validate_cert_dir(dir, cert_info, cacerts_file, cacerts_no_hdrs_file)
  # verify each cert file was copied and its top link generated
  cert_info.each do |file, relative_path, hash|
    dest_file = File.join(dir, relative_path, File.basename(file))
    expect( File.exist?(dest_file) ).to be true
    expect( IO.read(file) ).to eq IO.read(dest_file)

    dest_link = File.join(dir, "#{hash}.0")
    expect( File.exist?(dest_link) ).to be true
    expect( File.symlink?(dest_link) ).to be true

    if relative_path.empty?
      expected = File.basename(file)
    else
      expected = File.join(relative_path, File.basename(file))
    end
    expect( File.readlink(dest_link) ).to eq  expected
  end

  # verify aggregate CA certs files
  expect( IO.read(File.join(dir, 'cacerts.pem')) ).to eq IO.read(cacerts_file)
  expect( IO.read(File.join(dir, 'cacerts_no_headers.pem')) ).to eq IO.read(cacerts_no_hdrs_file)
end

describe provider_class do
  let(:files_dir) { File.join(File.dirname(__FILE__), 'files') }
  let(:cert_subj_hash) do
    {
     :cert1 => '4a44b594',
     :cert2 => 'ae3116e1',
     :cert3 => 'db039224'
    }
  end

  let(:cert1_file) { File.join(files_dir, 'cert1.pem') }
  let(:cert1_no_hdrs_file) { File.join(files_dir, 'cert1_no_headers.pem') }
  let(:cert2_file) { File.join(files_dir, 'cert2.pem') }
  let(:cert3_no_hdrs_file) { File.join(files_dir, 'cert3_no_headers.pem') }
  let(:cacerts_file) { File.join(files_dir, 'cacerts.pem') }
  let(:cacerts_no_hdrs_file) { File.join(files_dir, 'cacerts_no_headers.pem') }

  let(:cert_info) do
    # each entry has 3 fields
    # - fully qualified path to the test file
    # - relative path of file in the source/target test dir
    # - certificate subject hash for the file
    [
      [ cert1_file,         '',        cert_subj_hash[:cert1]],
      [ cert2_file,         'd2',      cert_subj_hash[:cert2]],
      [ cert3_no_hdrs_file, 'd3a/d3b', cert_subj_hash[:cert3]],
    ]
  end

  # Test some methods that do not rely upon or set internal provider state
  context 'stateless methods' do
    let(:provider) { resource.provider }
    let(:resource) do
      Puppet::Type.type(:pki_cert_sync).new({
        :name     => '/some/target/dir',
        :source   => '/some/source/dir',
        :provider => 'redhat'
      })
    end

    describe 'files_different?' do
      it 'returns false when the files have the same content' do
        expect( provider.files_different?(cert1_file, cert1_file) ).to eq false
      end

      it 'returns true when the files have different content' do
        expect( provider.files_different?(cert1_file, cert2_file) ).to eq true
      end

      it 'returns true when either file does not exist' do
        expect( provider.files_different?('/does/not/exist', cert2_file) ).to eq true
        expect( provider.files_different?(cert1_file, '/does/not/exist') ).to eq true
        expect( provider.files_different?('/does/not/exist', '/does/not/exist') ).to eq true
      end
    end

    describe 'strip_x509_headers' do
      it 'strips headers from a single certificate' do
        expected = IO.read(cert1_no_hdrs_file)
        expect( provider.strip_x509_headers(IO.read(cert1_file)) ).to eq expected
      end

      it 'strips headers from multiple certificates' do
        expected = IO.read(cacerts_no_hdrs_file)
        expect( provider.strip_x509_headers(IO.read(cacerts_file)) ).to eq expected
      end

      it 'retains the content of a single certificate when no headers exist' do
        expected = IO.read(cert1_no_hdrs_file)
        expect( provider.strip_x509_headers(IO.read(cert1_no_hdrs_file)) ).to eq expected
      end

      it 'retains the content of multiple certificates when no headers exist' do
        expected = IO.read(cacerts_no_hdrs_file)
        expect( provider.strip_x509_headers(IO.read(cacerts_no_hdrs_file)) ).to eq expected
      end

      it 'returns and empty string when no certificates exist' do
        expect( provider.strip_x509_headers('') ).to eq ''
      end
    end

  end

  # Test remaining provider operation via sequences of source(),
  # source_insync?(), and source=() calls.  This testing approach is
  # required for source_insync?() and source=(), because the source()
  # method generates internal and external state info needed by them.
  context 'stateful methods via scenarios' do
    before(:each) do
      @tmpdir = Dir.mktmpdir
      @source_dir = File.join(@tmpdir, 'source')
      FileUtils.mkdir_p(@source_dir)

      @target_dir = File.join(@tmpdir, 'target')
      FileUtils.mkdir_p(@target_dir)
    end

    after(:each) do
      FileUtils.remove_entry_secure(@tmpdir)
    end

    context 'source does not exist' do
      it 'fails when the source dir does not exist' do
        resource = Puppet::Type.type(:pki_cert_sync).new({
          :name     => @target_dir,
          :source   => '/does/not/exist/source',
          :provider => 'redhat'
        })
        provider = resource.provider

        msg = "'/does/not/exist/source' is not a valid directory"
        expect { provider.source }.to raise_error(/#{Regexp.escape(msg)}/)
      end
    end

    context 'target is out of sync' do
      let(:provider) { resource.provider }
      let(:resource) do
        Puppet::Type.type(:pki_cert_sync).new({
          :name     => @target_dir,
          :source   => @source_dir,
          :provider => 'redhat'
        })
      end

      context 'target does not exist' do
        it 'should create and populate the target dir' do
          populate_cert_dir(@source_dir, cert_info)

          its = provider.source
          expected_its = {
            'cert1.pem'              => '4a44b594.0',
            'd2/cert2.pem'           => 'ae3116e1.0',
            'd3a/d3b/cert3_no_headers.pem' => 'db039224.0',
            'cacerts.pem'            => 'cacerts.pem',
            'cacerts_no_headers.pem' => 'cacerts_no_headers.pem'
          }
          expect( its ).to eq expected_its

          expect( provider.source_insync?(its, @target_dir) ).to eq false
          provider.source = @target_dir

          validate_cert_dir(@target_dir, cert_info, cacerts_file, cacerts_no_hdrs_file)
        end
      end

      context 'target is missing a directory' do
        it 'should restore missing directory in the target dir' do
          # set up a incomplete target directory
          populate_cert_dir(@source_dir, cert_info)
          its = provider.source
          provider.source_insync?(its, @target_dir)
          provider.source = @target_dir
          FileUtils.rm_r(File.join(@target_dir, 'd3a'))

          # exercise provider
          its = provider.source
          expect( provider.source_insync?(its, @target_dir) ).to eq false
          provider.source = @target_dir

          validate_cert_dir(@target_dir, cert_info, cacerts_file, cacerts_no_hdrs_file)
        end
      end

      context 'target is missing a certificate file' do
        ['cert1.pem', 'cacerts.pem', 'cacerts_no_headers.pem'].each do |cert_file|
          it "should restore missing #{cert_file} in target dir" do
            # set up a incomplete target directory
            populate_cert_dir(@source_dir, cert_info)
            its = provider.source
            provider.source_insync?(its, @target_dir)
            provider.source = @target_dir
            FileUtils.rm(File.join(@target_dir, cert_file))

            # exercise provider
            its = provider.source
            expect( provider.source_insync?(its, @target_dir) ).to eq false
            provider.source = @target_dir

            validate_cert_dir(@target_dir, cert_info, cacerts_file, cacerts_no_hdrs_file)
          end
        end
      end

      context 'target is missing a link to a certificate file' do
        [:cert1, :cert2, :cert3].each do |cert|
          it "should restore missing link for #{:cert} in target dir" do
            # set up a incomplete target directory
            populate_cert_dir(@source_dir, cert_info)
            its = provider.source
            provider.source_insync?(its, @target_dir)
            provider.source = @target_dir
            FileUtils.rm(File.join(@target_dir, "#{cert_subj_hash[cert]}.0"))

            # exercise provider
            its = provider.source
            expect( provider.source_insync?(its, @target_dir) ).to eq false
            provider.source = @target_dir

            validate_cert_dir(@target_dir, cert_info, cacerts_file, cacerts_no_hdrs_file)
          end
        end
      end

      context 'target has a certificate file with differing content' do
        ['cert1.pem', 'cacerts.pem', 'cacerts_no_headers.pem'].each do |cert_file|
          it "should replace #{cert_file} in target dir" do
            # set up a incomplete target directory
            populate_cert_dir(@source_dir, cert_info)
            its = provider.source
            provider.source_insync?(its, @target_dir)
            provider.source = @target_dir
            FileUtils.cp(cert3_no_hdrs_file, File.join(@target_dir, cert_file))

            # exercise provider
            its = provider.source
            expect( provider.source_insync?(its, @target_dir) ).to eq false
            provider.source = @target_dir

            validate_cert_dir(@target_dir, cert_info, cacerts_file, cacerts_no_hdrs_file)
          end
        end
      end

      context 'target has an extra directory and purge is enabled' do
        it 'should remove extra directory in the target dir' do
          # set up a target directory with extra dir
          populate_cert_dir(@source_dir, cert_info)
          its = provider.source
          provider.source_insync?(its, @target_dir)
          provider.source = @target_dir
          extra_dir = File.join(@target_dir, 'extra')
          FileUtils.mkdir(extra_dir)
          FileUtils.cp(cert3_no_hdrs_file, extra_dir)

          # exercise provider
          its = provider.source
          expect( provider.source_insync?(its, @target_dir) ).to eq false
          provider.source = @target_dir

          validate_cert_dir(@target_dir, cert_info, cacerts_file, cacerts_no_hdrs_file)
          expect( Dir.exist?(extra_dir) ).to be false
        end
      end

      context 'target has an extra certificate file and purge is enabled' do
        it 'should remove extra cert file in the target dir' do
          # set up a target directory with extra cert
          populate_cert_dir(@source_dir, cert_info)
          its = provider.source
          provider.source_insync?(its, @target_dir)
          provider.source = @target_dir
          extra_cert = File.join(@target_dir, File.basename(cert1_no_hdrs_file))
          FileUtils.cp(cert1_no_hdrs_file, @target_dir)

          # exercise provider
          its = provider.source
          expect( provider.source_insync?(its, @target_dir) ).to eq false
          provider.source = @target_dir

          validate_cert_dir(@target_dir, cert_info, cacerts_file, cacerts_no_hdrs_file)
          expect( File.exist?(extra_cert) ).to be false
        end
      end
    end

    context 'target is in sync' do
      let(:provider) { resource.provider }
      let(:resource) do
        Puppet::Type.type(:pki_cert_sync).new({
          :name     => @target_dir,
          :source   => @source_dir,
          :provider => 'redhat',
          :purge    => false,
        })
      end

      context 'target matches source' do
        it 'should report it is in sync' do
          # set up a target directory
          populate_cert_dir(@source_dir, cert_info)
          its = provider.source
          provider.source_insync?(its, @target_dir)
          provider.source = @target_dir

          # exercise provider
          its = provider.source
          expect( provider.source_insync?(its, @target_dir) ).to eq true
        end
      end

      context 'target has an extra directory and purge is disabled' do
        it 'should report it is in sync' do
          # set up a target directory with extra dir
          populate_cert_dir(@source_dir, cert_info)
          its = provider.source
          provider.source_insync?(its, @target_dir)
          provider.source = @target_dir
          extra_dir = File.join(@target_dir, 'extra')
          FileUtils.mkdir(extra_dir)
          FileUtils.cp(cert3_no_hdrs_file, extra_dir)

          # exercise provider
          its = provider.source
          expect( provider.source_insync?(its, @target_dir) ).to eq true
        end
      end

      context 'target has an extra certificate file and purge is disabled' do
        it 'should report it is in sync' do
          # set up a target directory with extra cert
          populate_cert_dir(@source_dir, cert_info)
          its = provider.source
          provider.source_insync?(its, @target_dir)
          provider.source = @target_dir
          extra_cert = File.join(@target_dir, File.basename(cert1_no_hdrs_file))
          FileUtils.cp(cert1_no_hdrs_file, @target_dir)

          # exercise provider
          its = provider.source
          expect( provider.source_insync?(its, @target_dir) ).to eq true
        end
      end
    end

    context 'miscellaneous edge cases' do
      let(:provider) { resource.provider }
      let(:resource) do
        Puppet::Type.type(:pki_cert_sync).new({
          :name     => @target_dir,
          :source   => @source_dir,
          :provider => 'redhat'
        })
      end

      context 'source contains no valid certificate files' do
        it 'should not generate aggregate CA certs files' do
          # set up a target directory to already have CA certs files
          target_cacerts = File.join(@target_dir, 'cacerts.pem')
          FileUtils.cp(cacerts_file, target_cacerts)
          target_cacerts_no_hdrs = File.join(@target_dir, 'cacerts_no_headers.pem')
          FileUtils.cp(cacerts_no_hdrs_file, target_cacerts_no_hdrs)

          # exercise provider
          its = provider.source
          expect( provider.source_insync?(its, @target_dir) ).to eq false
          provider.source = @target_dir

          expect( File.exist?(target_cacerts) ).to be false
          expect( File.exist?(target_cacerts_no_hdrs) ).to be false

        end
      end

      context 'source contains non-certificate files' do
        it 'should not copy to target' do
          # set up a source directory with extra files:
          #   1 non-cert file and 1 malformed cert file
          populate_cert_dir(@source_dir, cert_info)
          File.open(File.join(@source_dir, 'README'),'w') do |file|
            file.puts "This is not a cert"
          end

          File.open(File.join(@source_dir, 'malformed.pem'),'w') do |file|
            # strip off last 3 lines of a valid cert
            invalid_cert = IO.readlines(cert1_file).pop(3).join("\n")
            file.puts invalid_cert
          end

          # exercise provider
          its = provider.source
          expect( provider.source_insync?(its, @target_dir) ).to eq false
          provider.source = @target_dir

          validate_cert_dir(@target_dir, cert_info, cacerts_file, cacerts_no_hdrs_file)
          expect( File.exist?(File.join(@target_dir, 'README')) ).to be false
          expect( File.exist?(File.join(@target_dir, 'malformed.pem')) ).to be false
        end
      end

      context 'source contains different certificate files with same subject hash' do
        it 'should create a unique link for each matching input' do
          dup_cert_info = [
            [ cert1_file,          '',    cert_subj_hash[:cert1]],
            [ cert1_no_hdrs_file,  '',    cert_subj_hash[:cert1]],
            [ cert1_file,         'dir1', cert_subj_hash[:cert1]],
            [ cert1_no_hdrs_file, 'dir1', cert_subj_hash[:cert1]],
          ]
          populate_cert_dir(@source_dir, dup_cert_info)

          # Create 3 more files with the same cert hash, but named <hash>.<num>:
          # - One at beginning of num range (0)
          # - One in the middle of the num range (3)
          # - One outside of num range (9)
          src = File.join(@source_dir, File.basename(cert1_file))
          cert_hash = cert_subj_hash[:cert1]
          FileUtils.cp(src, File.join(@source_dir, "#{cert_hash}.0"))
          FileUtils.cp(src, File.join(@source_dir, "#{cert_hash}.3"))
          FileUtils.cp(src, File.join(@source_dir, "#{cert_hash}.9"))

          # exercise provider
          its = provider.source
          expect( provider.source_insync?(its, @target_dir) ).to eq false
          provider.source = @target_dir

          Dir.chdir(@target_dir) do
            expected = [
              [ "#{cert_hash}.0",                                    nil ],
              [ File.basename(cert1_file),                           "#{cert_hash}.1"],
              [ File.basename(cert1_no_hdrs_file),                   "#{cert_hash}.2"],
              [ "#{cert_hash}.3",                                    nil ],
              [ File.join('dir1', File.basename(cert1_file)),         "#{cert_hash}.4"],
              [ File.join('dir1', File.basename(cert1_no_hdrs_file)), "#{cert_hash}.5"],
              [ "#{cert_hash}.9",                                    nil ]
            ]
            expected.each do |file, link|
              expect( File.exist?(file) ).to be true
              if link
                expect( File.exist?(link) ).to be true
                expect( File.symlink?(link) ).to be true
                expect( File.readlink(link) ).to eq file
              end
            end
          end
        end
      end

      context 'input files change between source() & source_insync?()' do
        it 'should handle missing source cert file gracefully' do
          populate_cert_dir(@source_dir, cert_info)
          its = provider.source
          FileUtils.rm(File.join(@source_dir, File.basename(cert1_file)))

          # really checking that this does not throw an exception
          expect( provider.source_insync?(its, @target_dir) ).to eq false
        end

        it 'should handle missing reference cacert file gracefully' do
          populate_cert_dir(@source_dir, cert_info)
          its = provider.source
          FileUtils.rm(File.join(@target_dir, '.cacerts.pem'))

          # really checking that this does not throw an exception
          expect( provider.source_insync?(its, @target_dir) ).to eq false
        end
      end

      context 'input files change between source() & source=()' do
        it 'should handle missing source cert file gracefully' do
          populate_cert_dir(@source_dir, cert_info)
          its = provider.source
          expect( provider.source_insync?(its, @target_dir) ).to eq false
          FileUtils.rm(File.join(@source_dir, File.basename(cert1_file)))

          # really checking that this does not throw an exception
          provider.source = @target_dir
        end

        it 'should handle missing reference cacert file gracefully' do
          populate_cert_dir(@source_dir, cert_info)
          its = provider.source
          expect( provider.source_insync?(its, @target_dir) ).to eq false
          FileUtils.rm(File.join(@target_dir, '.cacerts.pem'))

          # really checking that this does not throw an exception
          provider.source = @target_dir
        end
      end
    end
  end
end
