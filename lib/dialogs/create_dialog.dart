import 'dart:io';

import 'package:localization/localization.dart';
import 'package:wsl2distromanager/api/docker_images.dart';
import 'package:wsl2distromanager/components/analytics.dart';
import 'package:wsl2distromanager/api/wsl.dart';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:file_picker/file_picker.dart';
import 'package:wsl2distromanager/components/constants.dart';
import 'package:wsl2distromanager/components/helpers.dart';
import 'package:wsl2distromanager/components/notify.dart';
import 'package:wsl2distromanager/dialogs/dialogs.dart';
import 'package:wsl2distromanager/theme.dart';

/// Create Dialog
createDialog() {
  WSLApi api = WSLApi();
  final autoSuggestBox = TextEditingController();
  final locationController = TextEditingController();
  final nameController = TextEditingController();
  final userController = TextEditingController();
  plausible.event(page: 'create');

  // Get root context by Key
  final context = GlobalVariable.infobox.currentContext!;

  showDialog(
    useRootNavigator: false,
    context: context,
    builder: (context) {
      return ContentDialog(
        constraints: const BoxConstraints(maxHeight: 500.0, maxWidth: 450.0),
        title: Text('createnewinstance-text'.i18n()),
        content: SingleChildScrollView(
          child: CreateWidget(
            nameController: nameController,
            api: api,
            autoSuggestBox: autoSuggestBox,
            locationController: locationController,
            userController: userController,
          ),
        ),
        actions: [
          Button(
              child: Text('cancel-text'.i18n()),
              onPressed: () async {
                Navigator.pop(context);
              }),
          Button(
            onPressed: () async {
              // Run "runner" function from global key
              GlobalVariable.root.currentState!.runner(
                createInstance(
                  nameController,
                  locationController,
                  api,
                  autoSuggestBox,
                  userController,
                ),
              );
              Navigator.pop(context);
            },
            child: Text('create-text'.i18n()),
          ),
        ],
      );
    },
  );
}

progressFn(current, total, currentStep, totalStep) {
  if (currentStep != -1) {
    String progressInMB = (currentStep / 1024 / 1024).toStringAsFixed(2);
    // String totalInMB = (total / 1024 / 1024).toStringAsFixed(2);
    String percentage = (currentStep / totalStep * 100).toStringAsFixed(0);
    Notify.message('${'downloading-text'.i18n()}'
        ' Layer ${current + 1}/$total: $percentage% ($progressInMB MB)');
  } else {
    Notify.message('extractinglayers-text'.i18n(['$current', '$total']));
  }
}

Future<void> createInstance(
  TextEditingController nameController,
  TextEditingController locationController,
  WSLApi api,
  TextEditingController autoSuggestBox,
  TextEditingController userController,
) async {
  plausible.event(name: "wsl_create");
  String label = nameController.text;
  // Replace all special characters with _
  String name = label.replaceAll(RegExp('[^A-Za-z0-9]'), '_');
  if (name != '') {
    String distroName = autoSuggestBox.text;

    // Set paths
    Notify.message('creatinginstance-text'.i18n(), loading: true);
    String location = locationController.text;
    if (location == '') {
      location = prefs.getString("DistroPath") ?? defaultPath;
      location += '/$name';
    }

    // Check if docker image
    bool isDockerImage = false;
    if (distroName.startsWith('dockerhub:')) {
      isDockerImage = true;
      // Remove prefix
      distroName = autoSuggestBox.text.split('dockerhub:')[1];
      // Get tag
      if (!distroName.contains(':')) {
        distroName += ':latest';
      }
      String? image = distroName.split(':')[0];
      String? tag = distroName.split(':')[1];

      if (!distroName.contains('/')) {
        image = 'library/$image';
      }

      bool isDownloaded = false;
      // Check if image already downloaded
      if (await DockerImage().isDownloaded(image, tag: tag)) {
        isDownloaded = true;
      }

      // Check if image exists
      if (!isDownloaded && await DockerImage().hasImage(image, tag: tag)) {
        // Download image
        Notify.message('${'downloading-text'.i18n()}...');
        var docker = DockerImage()..distroName = distroName;
        try {
          await docker.getRootfs(name, image, tag: tag, progress: progressFn);
        } catch (e) {
          Notify.message('error-text'.i18n());
          return;
        }
        Notify.message('downloaded-text'.i18n());
        // Set distropath with distroName
        distroName = DockerImage().filename(image, tag);
      } else if (!isDownloaded) {
        Notify.message('distronotfound-text'.i18n());
        return;
      }

      if (isDownloaded) {
        // Set distropath with distroName
        distroName = DockerImage().filename(image, tag);
      }
    }

    // Navigator.of(context, rootNavigator: true).pop();

    // Create instance
    ProcessResult result = await api.create(
        name, distroName, location, (String msg) => Notify.message(msg),
        image: isDockerImage);

    // Check if instance was created then handle postprocessing
    if (result.exitCode != 0) {
      Notify.message(WSLApi().utf8Convert(result.stdout));
    } else {
      var userCmds = prefs.getStringList('UserCmds_$distroName');
      var groupCmds = prefs.getStringList('GroupCmds_$distroName');
      if (userCmds != null && groupCmds != null) {
        for (int i = 0; i < groupCmds.length; i++) {
          var cmd = groupCmds[i].replaceAll("/bin/sh -c ", "");
          cmd = cmd.replaceAll(RegExp(r'\s+'), ' ');
          await api.exec(name, [cmd]);
        }
        for (int i = 0; i < userCmds.length; i++) {
          var cmd = userCmds[i].replaceAll("/bin/sh -c ", "");
          // Replace multiple spaces with one
          cmd = cmd.replaceAll(RegExp(r'\s+'), ' ');
          await api.exec(name, [cmd]);
        }
      }
      String user = userController.text;
      if (user != '') {
        List<int> processes = await api.exec(name, [
          'apt-get update',
          'apt-get install -y sudo',
          'useradd -m -s /bin/bash -G sudo $user',
          'passwd $user',
          'echo \'$user ALL=(ALL) NOPASSWD:ALL\' >> /etc/sudoers.d/wslsudo',
          'echo -e \'[user]\ndefault = $user\' > /etc/wsl.conf',
        ]);
        bool success = true;
        for (dynamic process in processes) {
          if (process != 0) {
            success = false;
            break;
          }
        }
        if (success) {
          prefs.setString('StartPath_$name', '/home/$user');
          prefs.setString('StartUser_$name', user);

          Notify.message('createdinstance-text'.i18n());
        } else {
          Notify.message('createdinstancenouser-text'.i18n());
        }
      } else {
        // Install fake systemctl
        if (distroName.contains('Turnkey')) {
          // Set first start variable
          prefs.setBool('TurnkeyFirstStart_$name', true);
          Notify.message('installingfakesystemd-text'.i18n(), loading: true);
          WSLApi().execCmds(
              name,
              [
                'wget https://raw.githubusercontent.com/bostrot/'
                    'fake-systemd/master/systemctl -O /usr/bin/systemctl',
                'chmod +x /usr/bin/systemctl',
                '/usr/bin/systemctl',
              ],
              onMsg: (output) => null,
              onDone: () => Notify.message('createdinstance-text'.i18n()));
        } else {
          Notify.message('createdinstance-text'.i18n());
        }
      }
      // Save distro label
      prefs.setString('DistroName_$name', label);
      // Save distro path
      prefs.setString('Path_$name', location);
    }
    // Download distro check
  } else {
    Notify.message('entername-text'.i18n());
  }
}

class CreateWidget extends StatefulWidget {
  const CreateWidget({
    Key? key,
    required this.nameController,
    required this.api,
    required this.autoSuggestBox,
    required this.locationController,
    required this.userController,
  }) : super(key: key);

  final TextEditingController nameController;
  final WSLApi api;
  final TextEditingController autoSuggestBox;
  final TextEditingController locationController;
  final TextEditingController userController;

  @override
  State<CreateWidget> createState() => _CreateWidgetState();
}

class _CreateWidgetState extends State<CreateWidget> {
  bool turnkey = false;
  bool docker = false;
  FocusNode node = FocusNode();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 10.0,
        ),
        Container(
          height: 5.0,
        ),
        Tooltip(
          message: 'namehint-text'.i18n(),
          child: TextBox(
            controller: widget.nameController,
            placeholder: 'name-text'.i18n(),
            suffix: IconButton(
              icon: const Icon(FluentIcons.chrome_close, size: 11.0),
              onPressed: () {
                widget.nameController.clear();
              },
            ),
          ),
        ),
        Container(
          height: 10.0,
        ),
        Container(
          height: 5.0,
        ),
        Tooltip(
          message: 'pathtorootfshint-text'.i18n(),
          child: FutureBuilder<List<String>>(
              future: widget.api.getDownloadable(
                  (prefs.getString('RepoLink') ??
                      'http://ftp.halifax.rwth-aachen.de/'
                          'turnkeylinux/images/proxmox/'),
                  (e) => Notify.message(e)),
              builder: (context, snapshot) {
                List<AutoSuggestBoxItem<String>> list = [];
                if (snapshot.hasData) {
                  for (var i = 0; i < snapshot.data!.length; i++) {
                    list.add(AutoSuggestBoxItem<String>(
                      value: snapshot.data![i],
                      label: snapshot.data![i],
                    ));
                  }
                } else if (snapshot.hasError) {}
                return AutoSuggestBox(
                  placeholder: 'distroname-text'.i18n(),
                  controller: widget.autoSuggestBox,
                  items: list,
                  noResultsFoundBuilder: (context) =>
                      Builder(builder: (context) {
                    String text = 'noresultsfound-text'.i18n();
                    if (docker) {
                      text = widget.autoSuggestBox.text;
                      String image = text;
                      String tag = 'latest';
                      bool error = false;
                      try {
                        image = text.split(':')[1];
                      } catch (e) {
                        text = 'Check the image name and tag';
                        error = true;
                      }
                      try {
                        tag = text.split(':')[2];
                      } catch (e) {
                        // ignore
                      }
                      if (!error) {
                        text = 'Docker Image: $image:$tag';
                      }
                    } else {
                      text = 'No results found';
                    }
                    return Container(
                      padding: const EdgeInsets.all(10.0),
                      child: Text(
                        text,
                        style: TextStyle(
                          color: AppTheme().textColor,
                        ),
                      ),
                    );
                  }),
                  onChanged: (String value, TextChangedReason reason) {
                    if (value.contains('Turnkey')) {
                      if (!turnkey) {
                        setState(() {
                          turnkey = true;
                        });
                      }
                    } else if (turnkey) {
                      setState(() {
                        turnkey = false;
                      });
                    }
                    if (value.startsWith('dockerhub:')) {
                      setState(() {
                        docker = true;
                      });
                    } else {
                      setState(() {
                        docker = false;
                      });
                    }
                  },
                  trailingIcon: IconButton(
                    icon: const Icon(FluentIcons.open_folder_horizontal,
                        size: 15.0),
                    onPressed: () async {
                      FilePickerResult? result =
                          await FilePicker.platform.pickFiles(
                        type: FileType.custom,
                        allowedExtensions: ['*'],
                      );

                      if (result != null) {
                        widget.autoSuggestBox.text = result.files.single.path!;
                      } else {
                        // User canceled the picker
                      }
                    },
                  ),
                );
              }),
        ),
        ClickableUrl(
          clickEvent: 'docker_wiki_clicked',
          url: wikiDocker,
          text: 'usedistrofromdockerhub-text'.i18n(),
        ),
        Container(
          height: 5.0,
        ),
        Tooltip(
          message: 'savelocationhint-text'.i18n(),
          child: TextBox(
            controller: widget.locationController,
            placeholder: 'savelocationplaceholder-text'.i18n(),
            suffix: IconButton(
              icon: const Icon(FluentIcons.open_folder_horizontal, size: 15.0),
              onPressed: () async {
                String? path = await FilePicker.platform.getDirectoryPath();
                if (path != null) {
                  widget.locationController.text = path;
                } else {
                  // User canceled the picker
                }
              },
            ),
          ),
        ),
        Container(
          height: 10.0,
        ),
        turnkey
            ? Text('turnkeywarning-text'.i18n(),
                style: const TextStyle(fontStyle: FontStyle.italic))
            : Container(),
        !turnkey && !docker ? Container(height: 15.0) : Container(),
        !turnkey && !docker
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '${'createuser-text'.i18n()}:',
                  ),
                ],
              )
            : Container(),
        !turnkey && !docker
            ? Container(
                height: 5.0,
              )
            : Container(),
        !turnkey && !docker
            ? Tooltip(
                message: 'optionalusername-text'.i18n(),
                child: TextBox(
                  controller: widget.userController,
                  placeholder: 'optionaluser-text'.i18n(),
                ),
              )
            : Container(),
      ],
    );
  }
}
